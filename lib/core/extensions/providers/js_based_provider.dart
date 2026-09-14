import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';

import '../../domain/entity/multimedia_item.dart';
import '../base_provider.dart';
import '../engine/js_engine.dart';
import '../engine/js_bytecode_compiler.dart';
import '../models/extension_plugin.dart';
import '../../services/local_proxy_service.dart';
import '../../logger/app_logger.dart';

// Top-level function for compute() isolate
Map<String, List<MultimediaItem>> _parseHomeResults(dynamic result) {
  final map = <String, List<MultimediaItem>>{};
  if (result is Map) {
    result.forEach((key, value) {
      if (value is List) {
        map[key.toString()] = value
            .map(
              (e) => MultimediaItem.fromJson(
                Map<String, dynamic>.from(e as Map<dynamic, dynamic>),
              ),
            )
            .toList();
      }
    });
  }
  return map;
}

// Top-level function for compute() isolate
List<MultimediaItem> _parseSearchResults(dynamic result) {
  if (result is List) {
    return result
        .map(
          (e) => MultimediaItem.fromJson(
            Map<String, dynamic>.from(e as Map<dynamic, dynamic>),
          ),
        )
        .toList();
  }
  return [];
}

/// Caps the fanout over plugin-returned URLs. A plugin that returns 100
/// stream URLs would otherwise launch 100 concurrent compute() and
/// LocalProxyService calls.
const int _kStreamFanoutConcurrency = 8;

/// Hard ceiling on the per-call result count returned from a plugin. A
/// 1 M-entry list would otherwise cross the isolate boundary into compute().
const int _kMaxResultListLength = 5000;

/// Hard ceiling on stream URLs a single loadStreams call may yield.
const int _kMaxStreamsPerCall = 200;

/// Processes [items] in chunks of [concurrency] in parallel, preserving
/// input order. Each chunk awaits before the next starts.
Future<List<R>> _processInChunks<T, R>(
  Iterable<T> items,
  int concurrency,
  Future<R> Function(T item) work,
) async {
  final list = items.toList(growable: false);
  final results = List<R?>.filled(list.length, null);
  for (var i = 0; i < list.length; i += concurrency) {
    final end = (i + concurrency).clamp(0, list.length);
    final chunk = <Future<void>>[];
    for (var j = i; j < end; j++) {
      final idx = j;
      chunk.add(work(list[idx]).then((r) => results[idx] = r));
    }
    await Future.wait(chunk);
  }
  return results.cast<R>();
}

class JsBasedProvider extends SkyStreamProvider {
  // Bump whenever [_buildIife]'s wrapper text changes: the version is part of
  // the .qbc filename, so bytecode compiled from an older wrapper is ignored
  // rather than loaded.
  static const int _iifeWrapperVersion = 4;

  final JsEngineService _jsEngine;
  final String _scriptPath;
  String get scriptPath => _scriptPath;
  final String _packageName;
  @override
  String get packageName => _packageName;

  final String? _namespace;
  String? get namespace => _namespace;
  final String? _forcedName;
  final String? _providerId;
  // Scopes JS getPreference/setPreference — sub-providers share parent's namespace
  final String _jsPackageName;

  Future<void>? _initFuture;
  final String? _customBaseUrl;

  // Serializes calls into this plugin's exported functions. The shared JS
  // runtime is single-threaded but async-yields between bridge calls, so two
  // concurrent `search()` calls would interleave at every `await fetch(...)`
  // point and clobber each other's local variables.
  Future<void>? _invokeLock;

  Future<T> _serializedInvoke<T>(Future<T> Function() body) async {
    // Chain after the previous in-flight call.
    while (_invokeLock != null) {
      try {
        await _invokeLock;
      } catch (_) {
        // A predecessor's failure must not stop this call from running.
      }
    }
    final c = Completer<void>();
    _invokeLock = c.future;
    try {
      return await body();
    } finally {
      // Only release if we are still the holder.
      if (identical(_invokeLock, c.future)) _invokeLock = null;
      c.complete();
    }
  }

  // Optional shared script loader injected by ExtensionManager to deduplicate
  // file reads across sub-providers that share the same JS file.
  final Future<String?> Function()? _scriptLoader;

  JsBasedProvider(
    this._jsEngine,
    this._scriptPath, {
    required String packageName,
    String? jsPackageName,
    String? namespace,
    String? forcedName,
    Map<String, dynamic>? manifest,
    String? customBaseUrl,
    String? providerId,
    Future<String?> Function()? scriptLoader,
  }) : _packageName = packageName,
       _jsPackageName = jsPackageName ?? packageName,
       _namespace = namespace,
       _forcedName = forcedName,
       _customBaseUrl = customBaseUrl,
       _providerId = providerId,
       _scriptLoader = scriptLoader {
    // Populate manifest immediately so name/version/languages/supportedTypes
    // are available before lazy JS evaluation runs.
    if (manifest != null && manifest.isNotEmpty) {
      _manifest = Map<String, dynamic>.from(manifest);
      if (customBaseUrl != null && customBaseUrl.isNotEmpty) {
        _manifest['baseUrl'] = customBaseUrl;
      }
    }
  }

  Future<void> _ensureReady() {
    _initFuture ??= _init();
    return _initFuture!;
  }

  Future<void> get waitForInit => _ensureReady();

  @override
  void cancelInit() {
    _jsEngine.cancelPendingForTag(_packageName);
    // _init() detects JsEvalCancelledException and resets _initFuture itself.
  }

  Map<String, dynamic> _manifest = {};
  String? _error;

  // Per-sub-provider bytecode path. Only valid for file-based (non-asset) plugins.
  String? get _qbcPath {
    if (_scriptPath.startsWith('assets/')) return null;
    final dir = _scriptPath.substring(0, _scriptPath.lastIndexOf('/') + 1);
    final safeId = (_namespace ?? _packageName).replaceAll(
      RegExp(r'[^a-zA-Z0-9_]'),
      '_',
    );
    return '$dir${safeId}_v$_iifeWrapperVersion.qbc';
  }

  /// Where this provider's compiled wrapper bytecode lives, or null for asset
  /// plugins. Test seam, so a test driving the bytecode fast path does not
  /// hard-code [_iifeWrapperVersion] into a filename.
  @visibleForTesting
  String? get bytecodePath => _qbcPath;

  /// Name of the one-shot installer function this plugin's wrapper publishes
  /// on `globalThis`. Derived from the namespace, so it is unique per plugin
  /// (and per sub-provider). Null for un-namespaced raw scripts.
  String? get _installerGlobal => _namespace == null
      ? null
      : '${JsEngineService.kBridgeInstallerPrefix}$_namespace';

  /// Wraps the raw plugin source in a namespaced installer function with
  /// manifest, storage API and HTTP, all bound to this plugin's bridge
  /// capability token.
  ///
  /// The token itself is not in here: it is minted fresh per launch, and
  /// baking it into the wrapper text would make the compiled bytecode unusable
  /// on the next launch. Instead the wrapper publishes a one-shot installer
  /// under a name derived from this plugin's namespace, and
  /// [_installBridgeToken] takes that installer off `globalThis` and calls it
  /// with the token as an argument.
  ///
  /// The token must never travel through a slot shared between plugins.
  /// Concurrent plugin init is the normal path and each plugin's two evals are
  /// separated by real awaits, so one shared global would let the worker's
  /// FIFO eval queue interleave them and hand one plugin another's token. A
  /// per-plugin installer taking the token as an argument cannot cross, in any
  /// interleaving.
  @visibleForTesting
  String buildIife(String rawScript) => _buildIife(rawScript);

  String _buildIife(String rawScript) {
    if (_namespace == null) return rawScript;
    final manifestJson = jsonEncode(_manifest);
    final providerIdLine = _providerId != null
        ? "manifest.providerId = ${jsonEncode(_providerId)};"
        : "";
    final installerKey = jsonEncode(_installerGlobal);
    const tokenField = JsEngineService.kBridgeTokenField;
    return """
          globalThis[$installerKey] = function(__ssTok) {
              // __ssTok is this plugin's bridge capability token, passed in by
              // Dart. Every bridge call below carries it; Dart attributes the
              // call from the token and nothing else.

              const __ssSend = function(channel, params) {
                  params.$tokenField = __ssTok;
                  return sendMessage(channel, JSON.stringify(params));
              };
              const __ssAsync = function(channel, params) {
                  params.$tokenField = __ssTok;
                  return _dartAsyncCall(channel, params);
              };

              const manifest = $manifestJson;
              $providerIdLine

              const getPreference = (key) => {
                  return __ssSend('get_preference', { key: key });
              };

              const setPreference = (key, value) => {
                  return __ssSend('set_preference', { key: key, value: value });
              };

              // Same shape as the runtime's globals, but attributed. Declared
              // in this closure so the plugin body below binds to these and
              // not to the shared globalThis ones.
              const __ssHttp = function(method, url, headers, body) {
                  if (method === 'POST' && typeof headers === 'object' && headers !== null && !body && (headers.body || headers.headers)) {
                      body = headers.body; headers = headers.headers;
                  }
                  return __ssAsync('http_request', { method: method, url: url, headers: headers || {}, body: body });
              };
              const http_get = function(url, headers, cb) {
                  return __ssHttp('GET', url, headers, null).then(function(res) {
                      if (cb && typeof cb === 'function') cb(res);
                      return res;
                  });
              };
              const http_post = function(url, headers, body, cb) {
                  return __ssHttp('POST', url, headers, body).then(function(res) {
                      if (cb && typeof cb === 'function') cb(res);
                      return res;
                  });
              };
              const http_parallel = function(requests) {
                  return __ssAsync('http_parallel', { requests: requests });
              };
              const _fetch = async function(url) { return await http_get(url, {}); };

              var exports = (function() {
                  $rawScript

                  return {
                      getHome: (typeof getHome !== 'undefined') ? getHome : (typeof globalThis.getHome !== 'undefined' ? globalThis.getHome : undefined),
                      search: (typeof search !== 'undefined') ? search : (typeof globalThis.search !== 'undefined' ? globalThis.search : undefined),
                      load: (typeof load !== 'undefined') ? load : (typeof globalThis.load !== 'undefined' ? globalThis.load : undefined),
                      loadStreams: (typeof loadStreams !== 'undefined') ? loadStreams : (typeof globalThis.loadStreams !== 'undefined' ? globalThis.loadStreams : undefined),
                      getProviders: (typeof getProviders !== 'undefined') ? getProviders : (typeof globalThis.getProviders !== 'undefined' ? globalThis.getProviders : undefined),
                      getSettings: (typeof getSettings !== 'undefined') ? getSettings : (typeof globalThis.getSettings !== 'undefined' ? globalThis.getSettings : undefined),
                  };
              })();
              globalThis['$_namespace'] = exports;

              if (globalThis.getHome) delete globalThis.getHome;
              if (globalThis.search) delete globalThis.search;
              if (globalThis.load) delete globalThis.load;
              if (globalThis.loadStreams) delete globalThis.loadStreams;
              if (globalThis.getProviders) delete globalThis.getProviders;
              if (globalThis.getSettings) delete globalThis.getSettings;
          };
          """;
  }

  /// Mints this plugin's bridge capability token and evaluates the one line
  /// that hands it to the installer [_buildIife] published, then drops the
  /// installer.
  ///
  /// Runs after the wrapper eval, and only ever touches this plugin's own
  /// installer name, so another plugin's init interleaving here cannot cross
  /// the two tokens. Taking the installer off `globalThis` before calling it
  /// also makes it one-shot: a second, concurrent init of the same namespace
  /// finds nothing to call and leaves the already-installed exports alone.
  ///
  /// The text is generated per launch and deliberately never compiled to
  /// cached bytecode - it is the only place the token appears.
  ///
  /// The slot is read with `getOwnPropertyDescriptor` and the token is handed
  /// over only if it holds a plain, configurable, own data property, which is
  /// what this plugin's own wrapper assignment leaves there. Every plugin
  /// shares one `globalThis` and this installer name is derived from the
  /// namespace, so a hostile co-resident plugin could otherwise define a
  /// non-configurable accessor over it, capture the real installer and be
  /// handed this plugin's capability token - after which its bridge calls read
  /// and overwrite this plugin's stored credentials and settings.
  ///
  /// A squatted slot therefore fails closed: no token is handed out, the
  /// installer is never called, the plugin body does not run and the plugin is
  /// unavailable for the session with the reason logged. Denial of service is
  /// available to a co-resident plugin anyway; impersonation must not be.
  Future<void> _installBridgeToken() async {
    final namespace = _namespace;
    final installer = _installerGlobal;
    if (namespace == null || installer == null) return;
    final token = _jsEngine.mintBridgeToken(
      namespace: namespace,
      packageName: _jsPackageName,
    );
    final key = jsonEncode(installer);
    final warn = jsonEncode(
      '[bridge] installer slot $installer is not this plugin\'s own — '
      'refusing to hand over its capability token',
    );
    await _jsEngine.loadScript(
      '(function(){'
      'var __d = Object.getOwnPropertyDescriptor(globalThis, $key);'
      'if (!__d) return;'
      'try { delete globalThis[$key]; } catch (e) {}'
      'if (typeof __d.value !== "function" || !__d.configurable) {'
      'try { console.error($warn); } catch (e) {} return; }'
      '__d.value(${jsonEncode(token)});'
      '})();',
      tag: _packageName,
    );
  }

  Future<void> _init() async {
    String? rawScript;
    try {
      if (_scriptLoader != null) {
        rawScript = await _scriptLoader();
      } else if (_scriptPath.startsWith('assets/')) {
        rawScript = await rootBundle.loadString(_scriptPath);
      } else {
        final file = File(_scriptPath);
        if (await file.exists()) rawScript = await file.readAsString();
      }
    } catch (e) {
      if (kDebugMode) debugPrint("Error reading JS script ($_scriptPath): $e");
      _error = "Read: $e";
    }

    if (rawScript == null) {
      _error = "Not found";
      return;
    }

    final script = _buildIife(rawScript);
    final qbc = _qbcPath;

    try {
      // Fast path: load pre-compiled bytecode when available and fresh.
      if (qbc != null && !await JsBytecodeCompiler.isStale(_scriptPath, qbc)) {
        final bytes = await File(qbc).readAsBytes();
        await _jsEngine.loadBytes(bytes, tag: _packageName);
        // Nothing has run yet: the wrapper only published this plugin's
        // installer. Hand it the capability token to install the plugin.
        await _installBridgeToken();
        if (kDebugMode) {
          talker.debug("JsBasedProvider: Loaded bytecode for $_packageName");
        }
        return;
      }

      // Slow path: text eval, then compile bytecode in the background.
      await _jsEngine.loadScript(script, tag: _packageName);
      await _installBridgeToken();
      if (kDebugMode) {
        talker.debug("JsBasedProvider: Loaded script for $_packageName");
      }

      if (qbc != null) {
        // Fire-and-forget: compile bytecode for next launch.
        JsBytecodeCompiler.compile(script, qbc).ignore();
      }
    } on JsEvalCancelledException {
      // Search was cancelled before this IIFE ran. Reset so the next search
      // triggers a fresh _init() instead of replaying the cancelled future.
      _initFuture = null;
      _error = null;
      return;
    } catch (e) {
      _error = "Eval: $e";
      if (kDebugMode) {
        debugPrint(
          "JsBasedProvider: CRITICAL - Eval failed for $_packageName: $e",
        );
      }
    }
  }

  /// Called by ExtensionManager at install/update time to pre-compile bytecode.
  /// No-ops if bytecode is already fresh. Returns true if bytecode was written.
  Future<bool> precompile() async {
    final qbc = _qbcPath;
    if (qbc == null) return false;
    if (!await JsBytecodeCompiler.isStale(_scriptPath, qbc)) return false;
    String? rawScript;
    try {
      if (_scriptLoader != null) {
        rawScript = await _scriptLoader();
      } else {
        final file = File(_scriptPath);
        if (await file.exists()) rawScript = await file.readAsString();
      }
    } catch (_) {
      return false;
    }
    if (rawScript == null) return false;
    return JsBytecodeCompiler.compile(_buildIife(rawScript), qbc);
  }

  Future<void> deleteBytecode() async {
    final qbc = _qbcPath;
    if (qbc == null) return;
    try {
      final file = File(qbc);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  String _fn(String name) => _namespace != null ? '$_namespace.$name' : name;

  @override
  String get name {
    if (_forcedName != null) return _forcedName;
    if (_manifest['name'] != null) return _manifest['name'] as String;
    if (_error != null) return "Err: $_error";
    return "JS Extension";
  }

  @override
  String get mainUrl =>
      _customBaseUrl ?? (_manifest['baseUrl'] as String?) ?? "";

  @override
  String get version => (_manifest['version'] ?? 0).toString();

  @override
  List<String> get languages => _readManifestStringList(
    ['languages', 'language', 'lang'],
    fallback: const ['en'],
  );

  @override
  Set<ProviderType> get supportedTypes {
    final categories = _readManifestStringList([
      'categories',
      'tvTypes',
      'types',
    ]);
    if (categories.isEmpty) {
      return {ProviderType.movie};
    }

    final mapped = categories.map(_mapProviderType).toSet();
    if (mapped.isEmpty) {
      return {ProviderType.movie};
    }
    return mapped;
  }

  List<String> _readManifestStringList(
    List<String> keys, {
    List<String> fallback = const [],
  }) {
    for (final key in keys) {
      final value = _manifest[key];
      if (value is List) {
        final parsed = value.map((e) => e.toString()).toList();
        if (parsed.isNotEmpty) {
          return parsed;
        }
      }
      if (value is String && value.trim().isNotEmpty) {
        return [value];
      }
    }
    return fallback;
  }

  ProviderType _mapProviderType(String raw) {
    switch (raw.toLowerCase()) {
      case 'movie':
      case 'movies':
        return ProviderType.movie;
      case 'tv':
      case 'series':
      case 'tvseries':
      case 'tvshow':
      case 'tvshows':
        return ProviderType.series;
      case 'anime':
        return ProviderType.anime;
      case 'livetv':
      case 'iptv':
      case 'livestream':
        return ProviderType.livestream;
      default:
        return ProviderType.other;
    }
  }

  /// Calls the JS `getProviders()` export to fetch the live provider list.
  /// `invokeAsync` unwraps `{success:true, data:[...]}` automatically, so
  /// `result` is the raw List. Returns an empty list if not exported or on error.
  Future<List<PluginSubProvider>> getProviders() async {
    await _ensureReady();
    if (_error != null) return [];
    return _serializedInvoke(() async {
      try {
        final result = await _jsEngine.invokeAsync(_fn('getProviders'));
        if (result is List) {
          return result
              .whereType<Map<dynamic, dynamic>>()
              .map(
                (e) => PluginSubProvider.fromJson(Map<String, dynamic>.from(e)),
              )
              .where((p) => p.id.isNotEmpty)
              .toList();
        }
        if (kDebugMode) {
          debugPrint(
            'JsBasedProvider: getProviders returned unexpected type: ${result.runtimeType}',
          );
        }
        return [];
      } catch (e) {
        if (kDebugMode) {
          debugPrint(
            'JsBasedProvider: getProviders error for $_packageName: $e',
          );
        }
        return [];
      }
    });
  }

  /// Calls the optional JS `getSettings()` export.
  ///
  /// The plugin may return either a list directly or
  /// `{ settings: [...] }`. Invalid definitions are ignored.
  Future<List<PluginSettingDefinition>> getSettings() async {
    await _ensureReady();
    if (_error != null) return const [];

    return _serializedInvoke(() async {
      try {
        final result = await _jsEngine.invokeAsync(_fn('getSettings'));
        final dynamic rawSettings = result is Map && result['settings'] is List
            ? result['settings']
            : result;

        if (rawSettings is! List) return const [];

        return rawSettings
            .take(100)
            .whereType<Map<dynamic, dynamic>>()
            .map(
              (raw) => PluginSettingDefinition.fromJson(
                Map<String, dynamic>.from(raw),
              ),
            )
            .where((setting) => setting.key.isNotEmpty)
            .toList(growable: false);
      } catch (error) {
        if (kDebugMode) {
          debugPrint(
            'JsBasedProvider: getSettings unavailable for '
            '$_packageName: $error',
          );
        }
        return const [];
      }
    });
  }

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async {
    await _ensureReady();
    if (_error != null) throw JsPluginException("INIT_ERROR", _error!);
    return _serializedInvoke(() async {
      try {
        final result = await _jsEngine.invokeAsync(_fn('getHome'));
        if (result is Map) {
          // Bound the per-section list size before crossing the isolate
          // boundary: compute() has to serialise everything that crosses it.
          final bounded = <dynamic, dynamic>{};
          for (final entry in result.entries) {
            final v = entry.value;
            if (v is List && v.length > _kMaxResultListLength) {
              bounded[entry.key] = v.sublist(0, _kMaxResultListLength);
            } else {
              bounded[entry.key] = v;
            }
          }
          final map = await compute(_parseHomeResults, bounded);
          return map;
        }
        throw Exception("Extension returned invalid home data (not a map).");
      } on JsPluginException catch (e) {
        if (kDebugMode) debugPrint("JsPluginException in getHome: $e");
        talker.error("JsPluginException in getHome: $e");
        rethrow;
      } catch (e) {
        if (kDebugMode) debugPrint("Error in getHome: $e");
        talker.error("Error in getHome: $e");
        throw Exception("Failed to load home content: $e");
      }
    });
  }

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async {
    await _ensureReady();
    if (_error != null) throw JsPluginException("INIT_ERROR", _error!);
    return _serializedInvoke(() async {
      try {
        final result = await _jsEngine.invokeAsync(_fn('search'), [
          query,
        ], cancelToken);
        if (result is List) {
          // Cap before compute() so a malicious plugin cannot force the
          // isolate boundary to serialise an unbounded payload.
          final bounded = result.length > _kMaxResultListLength
              ? result.sublist(0, _kMaxResultListLength)
              : result;
          return await compute(_parseSearchResults, bounded);
        }
        return <MultimediaItem>[];
      } on JsPluginException catch (e) {
        if (kDebugMode) debugPrint("JsPluginException in search: $e");
        talker.error("JsPluginException in search: $e");
        rethrow;
      } catch (e) {
        if (kDebugMode) debugPrint("Error in search: $e");
        talker.error("Error in search: $e");
        return <MultimediaItem>[];
      }
    });
  }

  @override
  Future<MultimediaItem> getDetails(String url) async {
    await _ensureReady();
    if (_error != null) throw JsPluginException("INIT_ERROR", _error!);
    // Serialized like every other export: the engine cancels a namespace's
    // in-flight HTTP when that namespace's last invocation ends, so two
    // overlapping invocations on one namespace would let either one's end
    // hang up on the other's sockets.
    return _serializedInvoke(() async {
      try {
        final result = await _jsEngine.invokeAsync(_fn('load'), [url]);
        if (result is Map) {
          final map = Map<String, dynamic>.from(result);
          if (map['url'] == null || map['url'].toString().isEmpty) {
            map['url'] = url;
          }
          return MultimediaItem.fromJson(map);
        }
        throw Exception("Extension returned invalid detail data.");
      } on JsPluginException catch (e) {
        if (kDebugMode) debugPrint("JsPluginException in getDetails: $e");
        talker.error("JsPluginException in getDetails: $e");
        rethrow;
      } catch (e) {
        if (kDebugMode) debugPrint("Error in getDetails: $e");
        talker.error("Error in getDetails: $e");
        return MultimediaItem(title: "Error: $e", url: url, posterUrl: "");
      }
    });
  }

  @override
  Future<List<StreamResult>> loadStreams(String url) async {
    await _ensureReady();
    if (_error != null) throw JsPluginException("INIT_ERROR", _error!);
    await LocalProxyService.instance.startServer();

    return _serializedInvoke(() async {
      try {
        final result = await _jsEngine.invokeAsync(_fn('loadStreams'), [url]);
        if (result is List) {
          // Cap the per-call result list: a misbehaving plugin could
          // otherwise push tens of thousands of entries through the fanout
          // below.
          final bounded = result.length > _kMaxStreamsPerCall
              ? result.sublist(0, _kMaxStreamsPerCall)
              : result;
          if (kDebugMode && result.length > _kMaxStreamsPerCall) {
            debugPrint(
              "[$_packageName] loadStreams returned ${result.length} entries — "
              "capping to $_kMaxStreamsPerCall (audit M25).",
            );
          }
          // Bounded-concurrency chunks: an unbounded Future.wait would spawn
          // one compute() and one proxy fetch per entry.
          return await _processInChunks(bounded, _kStreamFanoutConcurrency, (
            e,
          ) async {
            final map = Map<String, dynamic>.from(e as Map);
            String finalUrl = map['url'] as String;

            if (finalUrl.startsWith("magic_m3u8:")) {
              try {
                final base64Content = finalUrl.substring("magic_m3u8:".length);
                final m3u8Content = await compute(
                  _processMagicM3u8,
                  base64Content,
                );
                finalUrl = LocalProxyService.instance.serveM3u8(m3u8Content);
              } catch (err) {
                if (kDebugMode) debugPrint("Magic M3U8 Error: $err");
              }
            }
            // A MAGIC_PROXY url goes through the local proxy, which injects
            // the headers HLS segment requests need.
            else if (finalUrl.startsWith("MAGIC_PROXY_v1") ||
                finalUrl.startsWith("MAGIC_PROXY:")) {
              try {
                final bool isV1 = finalUrl.startsWith("MAGIC_PROXY_v1");
                final b64Url = finalUrl.substring(
                  isV1 ? "MAGIC_PROXY_v1".length : "MAGIC_PROXY:".length,
                );
                final realUrlBytes = base64Decode(b64Url);
                final realUrl = utf8.decode(realUrlBytes);

                Map<String, String>? sticky = map['headers'] != null
                    ? Map<String, String>.from(map['headers'] as Map)
                    : null;

                if (mainUrl.isNotEmpty) {
                  try {
                    final baseUri = Uri.parse(mainUrl);
                    final jarCookies = await _jsEngine.getCookiesForUri(
                      baseUri,
                    );
                    if (jarCookies.isNotEmpty) {
                      final cookieHeader = jarCookies
                          .map((c) => '${c.name}=${c.value}')
                          .join('; ');
                      sticky ??= <String, String>{};
                      String? existingKey;
                      sticky.forEach((k, v) {
                        if (k.toLowerCase() == 'cookie') existingKey = k;
                      });
                      final existingCookie = existingKey != null
                          ? sticky[existingKey]
                          : null;
                      if (existingCookie != null && existingCookie.isNotEmpty) {
                        final Map<String, String> merged = {};
                        for (final pair in existingCookie.split(';')) {
                          final parts = pair.split('=');
                          if (parts.length >= 2) {
                            merged[parts[0].trim()] = parts
                                .sublist(1)
                                .join('=')
                                .trim();
                          }
                        }
                        for (final c in jarCookies) {
                          merged[c.name] = c.value;
                        }
                        sticky[existingKey!] = merged.entries
                            .map((e) => '${e.key}=${e.value}')
                            .join('; ');
                      } else {
                        sticky['Cookie'] = cookieHeader;
                      }
                    }
                  } catch (e) {
                    if (kDebugMode) {
                      debugPrint(
                        "Failed to copy cookies from JS engine jar to proxy headers: $e",
                      );
                    }
                  }
                }

                finalUrl = LocalProxyService.instance.getProxyUrl(
                  realUrl,
                  headers: sticky,
                );
              } catch (e) {
                if (kDebugMode) {
                  debugPrint("Error decoding MAGIC_PROXY_v1 url: $e");
                }
              }
            } else if (finalUrl.startsWith("MAGIC_PROXY_v2")) {
              try {
                final b64Json = finalUrl.substring("MAGIC_PROXY_v2".length);
                final jsonBytes = base64Decode(b64Json);
                final decodedJson = utf8.decode(jsonBytes);
                final Map<String, dynamic> config =
                    jsonDecode(decodedJson) as Map<String, dynamic>;

                final String realUrl = config['url'] as String;
                Map<String, String>? sticky = config['headers'] != null
                    ? Map<String, String>.from(config['headers'] as Map)
                    : (map['headers'] != null
                          ? Map<String, String>.from(map['headers'] as Map)
                          : null);

                if (mainUrl.isNotEmpty) {
                  try {
                    final baseUri = Uri.parse(mainUrl);
                    final jarCookies = await _jsEngine.getCookiesForUri(
                      baseUri,
                    );
                    if (jarCookies.isNotEmpty) {
                      final cookieHeader = jarCookies
                          .map((c) => '${c.name}=${c.value}')
                          .join('; ');
                      sticky ??= <String, String>{};
                      String? existingKey;
                      sticky.forEach((k, v) {
                        if (k.toLowerCase() == 'cookie') existingKey = k;
                      });
                      final existingCookie = existingKey != null
                          ? sticky[existingKey]
                          : null;
                      if (existingCookie != null && existingCookie.isNotEmpty) {
                        final Map<String, String> merged = {};
                        for (final pair in existingCookie.split(';')) {
                          final parts = pair.split('=');
                          if (parts.length >= 2) {
                            merged[parts[0].trim()] = parts
                                .sublist(1)
                                .join('=')
                                .trim();
                          }
                        }
                        for (final c in jarCookies) {
                          merged[c.name] = c.value;
                        }
                        sticky[existingKey!] = merged.entries
                            .map((e) => '${e.key}=${e.value}')
                            .join('; ');
                      } else {
                        sticky['Cookie'] = cookieHeader;
                      }
                    }
                  } catch (e) {
                    if (kDebugMode) {
                      debugPrint(
                        "Failed to copy cookies from JS engine jar to proxy headers: $e",
                      );
                    }
                  }
                }

                ProxyOptions? options;
                if (config['options'] != null) {
                  options = ProxyOptions.fromJson(
                    config['options'] as Map<String, dynamic>,
                  );
                }

                finalUrl = LocalProxyService.instance.getProxyUrl(
                  realUrl,
                  headers: sticky,
                  options: options,
                );
              } catch (e) {
                if (kDebugMode) {
                  debugPrint("Error decoding MAGIC_PROXY_v2 url: $e");
                }
              }
            }

            return StreamResult(
              url: finalUrl,
              source: (map['source'] as String?) ?? "Auto",
              headers: map['headers'] != null
                  ? Map<String, String>.from(map['headers'] as Map)
                  : null,
              subtitles: map['subtitles'] != null
                  ? (map['subtitles'] as List)
                        .map(
                          (s) => SubtitleFile.fromJson(
                            Map<String, dynamic>.from(s as Map),
                          ),
                        )
                        .toList()
                  : null,
              drmKid: map['drmKid'] as String?,
              drmKey: map['drmKey'] as String?,
              licenseUrl: map['licenseUrl'] as String?,
            );
          });
        }
        return [];
      } on JsPluginException catch (e) {
        if (kDebugMode) debugPrint("JsPluginException in loadStreams: $e");
        talker.error("JsPluginException in loadStreams: $e");
        rethrow;
      } catch (e) {
        if (kDebugMode) debugPrint("Error in loadStreams: $e");
        talker.error("Error in loadStreams: $e");
        return <StreamResult>[];
      }
    });
  }
}

// Global top-level function for compute() compatibility
String _processMagicM3u8(String base64Content) {
  final bytes = base64.decode(base64Content);
  final m3u8Content = utf8.decode(bytes);

  // Any MAGIC_PROXY_v1 rewriting is left to the caller: this runs in an
  // isolate, where LocalProxyService is not reachable.

  return m3u8Content;
}
