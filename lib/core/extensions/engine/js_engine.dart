import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show RootIsolateToken;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as wv;
import '../../storage/extension_repository.dart';
import '../../network/cloudflare_bypass.dart';
import '../../logger/app_logger.dart';
import '../../network/dio_client_provider.dart';
import '../../network/http_defaults.dart';

import 'js_engine_worker.dart';

export 'js_engine_worker.dart' show jsEngineWorkerEntry;

/// Thrown when a queued JS eval is removed by [JsEngineService.cancelPendingForTag].
class JsEvalCancelledException implements Exception {
  const JsEvalCancelledException();
}

/// Hard ceiling on the body of a single plugin HTTP response, in bytes.
///
/// A scraper fetches HTML pages and JSON APIs; the largest thing a legitimate
/// one asks for is a few hundred KB. 8 MB is far past that and matches the
/// ceiling [NuvioEngine] already applies to its own scrapers. Anything bigger
/// is a plugin that has mistaken a media URL for a page, and buffering it
/// would cost that much RAM on a 2016 TV box plus the encode to hand it to
/// QuickJS. Audit W24.
const int kJsHttpMaxResponseBytes = 8 * 1024 * 1024;

/// Thrown by [fetchCappedPlainBody] when a plugin's HTTP response exceeds
/// [kJsHttpMaxResponseBytes]. Surfaces to the plugin through the normal
/// bridge error path, the same as a connection failure.
class JsHttpResponseTooLargeException implements Exception {
  final String url;
  final int limit;

  /// Content-Length that caused the request to be rejected before reading a
  /// byte, or null when the cap was hit while streaming.
  final int? declaredLength;

  const JsHttpResponseTooLargeException(
    this.url,
    this.limit, [
    this.declaredLength,
  ]);

  @override
  String toString() =>
      'JsHttpResponseTooLargeException: response from $url exceeds the '
      '$limit byte plugin response limit'
      '${declaredLength != null ? ' (Content-Length: $declaredLength)' : ''}';
}

/// A plugin HTTP response whose body has been read under a size cap.
@visibleForTesting
class CappedHttpResponse {
  final int statusCode;
  final String body;
  final Headers headers;
  final Uri realUri;

  const CappedHttpResponse({
    required this.statusCode,
    required this.body,
    required this.headers,
    required this.realUri,
  });
}

/// Performs a plugin HTTP request and reads at most [limit] bytes of body.
///
/// Streams the response instead of letting Dio buffer it whole
/// (`ResponseType.plain`), so an oversized body is refused rather than
/// materialised: a declared Content-Length over the cap is rejected before
/// any body is read, and an undeclared or lying one aborts mid-stream, which
/// cancels the subscription and closes the connection. Decoding matches
/// Dio's own plain transform (`utf8.decode(..., allowMalformed: true)`), so a
/// response under the cap is byte-identical to what plugins saw before.
/// Audit W24.
@visibleForTesting
Future<CappedHttpResponse> fetchCappedPlainBody(
  Dio dio,
  String url, {
  required Options options,
  Object? data,
  CancelToken? cancelToken,
  int limit = kJsHttpMaxResponseBytes,
}) async {
  final response = await dio.request<ResponseBody>(
    url,
    data: data,
    cancelToken: cancelToken,
    options: options.copyWith(responseType: ResponseType.stream),
  );
  final stream = response.data?.stream;

  final declared = int.tryParse(
    response.headers.value(Headers.contentLengthHeader) ?? '',
  );
  if (declared != null && declared > limit) {
    // Never subscribe: hang up before the first byte of body arrives.
    if (stream != null) {
      try {
        await stream.listen(null).cancel();
      } catch (_) {}
    }
    throw JsHttpResponseTooLargeException(url, limit, declared);
  }

  final buffer = BytesBuilder(copy: false);
  if (stream != null) {
    await for (final chunk in stream) {
      buffer.add(chunk);
      // Throwing out of an await-for cancels the subscription, which tears
      // down the socket — the rest of the file is never transferred.
      if (buffer.length > limit) {
        throw JsHttpResponseTooLargeException(url, limit);
      }
    }
  }

  return CappedHttpResponse(
    statusCode: response.statusCode ?? 0,
    body: utf8.decode(buffer.takeBytes(), allowMalformed: true),
    headers: response.headers,
    realUri: response.realUri,
  );
}

class JsPluginException implements Exception {
  final String code;
  final String message;
  final String? pluginId;

  JsPluginException(this.code, this.message, {this.pluginId});

  @override
  String toString() => 'JsPluginException[$code]: $message';
}

/// Who a bridge call belongs to.
///
/// Minted by Dart at plugin-load time and handed to exactly one plugin IIFE
/// (see `JsBasedProvider._buildIife`). Nothing in here is ever taken from the
/// message a plugin sends — the plugin only echoes back the opaque token, and
/// the token is what selects this record. Audit W12.
@immutable
class PluginBridgeIdentity {
  /// The exact JS namespace the plugin's exports live under, e.g.
  /// `com_foo_bar__sub1`. One [JsBasedProvider] instance, one raw namespace,
  /// and that instance serialises its own invocations — so this is the unit
  /// that HTTP cancellation is scoped to.
  final String rawNamespace;

  /// The plugin (not sub-provider) the raw namespace belongs to, e.g.
  /// `com_foo_bar`. All of a plugin's sub-providers share one key space.
  final String storageNamespace;

  /// The plugin's reverse-DNS package name, e.g. `com.foo.bar`. Preferences
  /// are stored under `<packageName>:<key>` because that is the key the
  /// settings UI reads and writes.
  final String packageName;

  const PluginBridgeIdentity({
    required this.rawNamespace,
    required this.storageNamespace,
    required this.packageName,
  });
}

final jsEngineProvider = Provider.autoDispose<JsEngineService>((ref) {
  final storage = ref.read(extensionRepositoryProvider);
  final dio = ref.read(dioClientProvider);
  final service = JsEngineService(storage, dio);
  ref.onDispose(() => service.dispose());
  return service;
});

// ── Proxy class — lives on the main isolate ───────────────────────────────────

class JsEngineService {
  final Dio _dio;
  final ExtensionRepository _storage;

  late final PersistCookieJar _cookieJar;
  bool _cookieJarReady = false;

  // Pending load/invoke operations keyed by the sequential ID sent to worker.
  final _pendingLoads = <int, Completer<void>>{};
  final _pendingInvokes = <int, Completer<dynamic>>{};
  // Per-invoke Dio cancel tokens so JS HTTP requests can be cancelled on timeout.
  final _cancelTokens = <int, CancelToken>{};
  // Maps invoke ID → calling plugin's raw namespace, extracted from the
  // dotted function name (e.g. "myPlugin__sub.search" → "myPlugin__sub").
  // Dart writes the function name, so this is authoritative. Used to know
  // how many invocations a namespace has outstanding. Audit B5 / PR-08b.
  final _invokeNamespaces = <int, String>{};

  // ── Bridge attribution (audit W12) ────────────────────────────────────────
  // A bridge call is attributed by an opaque capability token that Dart mints
  // per plugin and splices into that plugin's IIFE. The plugin echoes the
  // token back on every bridge call; the token is the ONLY thing consulted.
  // Nothing else in the message — packageName, and formerly the worker's
  // "most recently started callback" id — can move a call into another
  // plugin's key space.
  final _bridgeTokens = <String, PluginBridgeIdentity>{};
  final _tokensByNamespace = <String, String>{};

  // Raw namespace → the Dio cancel tokens of that namespace's in-flight
  // plugin HTTP. Cancelled when the namespace's last outstanding invocation
  // ends, so an abandoned search does not leave requests running.
  final _httpScopes = <String, Set<CancelToken>>{};
  // Raw namespace → number of invocations currently in flight for it.
  final _outstandingInvokes = <String, int>{};

  int _nextId = 0;

  // Worker isolate communication
  Isolate? _isolate;
  late final SendPort _workerPort;
  final _workerReady = Completer<void>();
  late final ReceivePort _rx;

  JsEngineService(this._storage, this._dio) {
    _rx = ReceivePort();
    _rx.listen(_handleWorkerMsg);
    initCookieJar();
    final token = RootIsolateToken.instance!;
    Isolate.spawn(jsEngineWorkerEntry, [_rx.sendPort, token]).then((iso) {
      _isolate = iso;
    });
  }

  /// Builds an engine that talks to [workerPort] instead of spawning the
  /// QuickJS worker isolate, so the bridge can be driven directly from a
  /// test. No isolate, no cookie jar, no path_provider.
  @visibleForTesting
  JsEngineService.withWorkerPort(
    this._storage,
    this._dio,
    SendPort workerPort,
  ) {
    _rx = ReceivePort();
    _workerPort = workerPort;
    _workerReady.complete();
  }

  /// Delivers a worker→main message exactly as the ReceivePort would.
  @visibleForTesting
  void handleWorkerMessage(dynamic msg) => _handleWorkerMsg(msg);

  /// Opens the Cloudflare-clearance cookie jar.
  ///
  /// Application Support, never Documents. The jar holds `cf_clearance` and
  /// whatever session cookies the scraped sites set, and on iOS the app
  /// declares `UIFileSharingEnabled` and
  /// `LSSupportsOpeningDocumentsInPlace`, so anything in Documents is listed
  /// in Files.app and copied verbatim into an unencrypted Finder backup that
  /// any paired computer can read. That turns a scraping cache into a record
  /// of which sites the user visits plus a usable session handoff.
  ///
  /// Moving the jar orphans existing clearances: the cost is one Cloudflare
  /// challenge, once, per site.
  ///
  /// Public only so a test can drive it - the production caller is the
  /// constructor, and the test constructor deliberately does not open a jar.
  @visibleForTesting
  Future<void> initCookieJar() async {
    try {
      final dir = await getApplicationSupportDirectory();
      _cookieJar = PersistCookieJar(
        storage: FileStorage('${dir.path}/.cf_cookies/'),
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[CookieJar] Persist init failed, using RAM: $e');
      }
      _cookieJar = PersistCookieJar();
    }
    _cookieJarReady = true;
    final hasCfInterceptor = _dio.interceptors.any(
      (i) => i is CfOnlyCookieInterceptor,
    );
    if (!hasCfInterceptor) {
      _dio.interceptors.add(CfOnlyCookieInterceptor(_cookieJar));
    }
  }

  // ── Worker message handler ────────────────────────────────────────────────

  void _handleWorkerMsg(dynamic msg) {
    if (msg is! Map<dynamic, dynamic>) return;
    final m = msg;

    if (m.containsKey(_mReady)) {
      _workerPort = m[_mReady] as SendPort;
      _workerReady.complete();
      return;
    }

    if (m.containsKey(_mLoadDone)) {
      final id = m[_mLoadDone] as int;
      _pendingLoads.remove(id)?.complete();
      return;
    }

    if (m.containsKey(_mLoadErr)) {
      final id = m[_mLoadErr] as int;
      final err = m['msg'] as String? ?? 'load error';
      _pendingLoads.remove(id)?.completeError(Exception(err));
      return;
    }

    if (m.containsKey(_mInvokeResult)) {
      final id = m[_mInvokeResult] as int;
      final err = m['err'];
      final result = m['result'];
      _retireInvoke(id);
      final c = _pendingInvokes.remove(id);
      if (c != null && !c.isCompleted) {
        if (err != null) {
          c.completeError(Exception(err.toString()));
        } else {
          c.complete(result);
        }
      }
      return;
    }

    if (m.containsKey(_mBridge)) {
      _handleBridgeRequest(m);
      return;
    }

    if (m.containsKey(_mLog)) {
      final msg = m[_mLog] as String;
      final isErr = m['err'] as bool? ?? false;
      if (isErr) {
        talker.error('[JS] $msg');
        if (kDebugMode) debugPrint('[JS ERROR] $msg');
      } else {
        talker.debug('[JS] $msg');
        if (kDebugMode) debugPrint('[JS LOG] $msg');
      }
      return;
    }
  }

  // ── IO bridge dispatch ────────────────────────────────────────────────────

  /// Hands a bridge result back to the worker.
  ///
  /// [result] crosses the port as a live Dart object rather than a JSON
  /// string: the worker has to splice JSON into a JS eval anyway, so it does
  /// the encode on its own isolate. Audit W24 — `jsonEncode` of a multi-MB
  /// scraped page here is several hundred milliseconds of dropped frames on
  /// the isolate that draws the UI, in the middle of a search.
  void _reply(int bid, String jsId, Object? result, {bool isError = false}) {
    _workerPort.send(
      buildBridgeResponse(
        bid: bid,
        jsId: jsId,
        result: result,
        isError: isError,
      ),
    );
  }

  void _handleBridgeRequest(Map<dynamic, dynamic> m) {
    final bid = m['bid'] as int;
    final channel = m['ch'] as String;
    final argsJson = m['aj'] as String;
    final Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(argsJson) as Map<String, dynamic>;
    } catch (e) {
      // Decoded once for every channel now, so a malformed payload must not
      // take the whole bridge listener down with it.
      talker.error('[bridge] $channel: undecodable payload: $e');
      return;
    }
    final jsId = parsed['id'] as String?;

    // Attribution. The ONLY thing that decides which plugin this call belongs
    // to is the capability token Dart minted for that plugin. Audit W12: this
    // used to be a reverse lookup against the worker's "most recently started
    // callback" id, which (a) was guessed on this side as `cb_$invokeId` while
    // the worker mints `cb_$callbackCount` — two counters that diverge by the
    // number of script loads, so the lookup never matched — and (b) even on a
    // match named whichever invocation started last, not the one on the JS
    // stack. Both failure modes put one plugin's data in another's hands.
    final caller = _identityFor(parsed);

    switch (channel) {
      case 'http_request':
        final scope = caller?.rawNamespace;
        final reqToken = _acquireHttpToken(scope);
        _handleHttp(
              argsJson,
              cancelToken: reqToken,
              callerNamespace: caller?.storageNamespace,
            )
            .then((result) {
              _releaseHttpToken(scope, reqToken);
              if (jsId != null) _reply(bid, jsId, result);
            })
            .catchError((Object e) {
              _releaseHttpToken(scope, reqToken);
              if (jsId != null) _reply(bid, jsId, e.toString(), isError: true);
            });

      case 'http_parallel':
        final requests = (parsed['requests'] as List)
            .cast<Map<String, dynamic>>();
        final scope = caller?.rawNamespace;
        final reqToken = _acquireHttpToken(scope);

        Future.wait(
              requests.map(
                (r) => _handleHttp(
                  jsonEncode(r),
                  cancelToken: reqToken,
                  callerNamespace: caller?.storageNamespace,
                ),
              ),
            )
            .then((results) {
              _releaseHttpToken(scope, reqToken);
              if (jsId != null) _reply(bid, jsId, results);
            })
            .catchError((Object e) {
              _releaseHttpToken(scope, reqToken);
              if (jsId != null) _reply(bid, jsId, e.toString(), isError: true);
            });

      case 'get_storage':
        if (caller == null) {
          _denyUnattributed(channel, bid, jsId);
          return;
        }
        final key = parsed['key'] as String? ?? '';
        // Every write below is namespaced, so the un-prefixed key can only
        // ever hold data from before attribution worked. It is not read back:
        // a flat key has no recorded owner, so serving it would hand one
        // plugin whatever another plugin left there.
        final value = _storage.getExtensionData(
          '${caller.storageNamespace}::$key',
        );
        if (jsId != null) _reply(bid, jsId, value);

      case 'set_storage':
        if (caller == null) {
          _denyUnattributed(channel, bid, jsId);
          return;
        }
        final key = parsed['key'] as String? ?? '';
        final value = parsed['value'] as String?;
        _storage
            .setExtensionData('${caller.storageNamespace}::$key', value)
            .ignore();

      case 'get_preference':
        // Direct sendMessage('get_preference', ...) — sync bridge, returns null
        // from background isolate. Plugins using the JS polyfill getPreference()
        // go through get_storage instead, which is async.
        if (caller == null) {
          _denyUnattributed(channel, bid, jsId);
          return;
        }
        final key = parsed['key'] as String? ?? '';
        final value = _storage.getExtensionData('${caller.packageName}:$key');
        if (jsId != null) _reply(bid, jsId, value);

      case 'set_preference':
        if (caller == null) {
          _denyUnattributed(channel, bid, jsId);
          return;
        }
        final key = parsed['key'] as String? ?? '';
        final value = parsed['value'] as String?;
        _storage.setExtensionData('${caller.packageName}:$key', value).ignore();

      case 'solve_captcha':
        if (jsId != null) _reply(bid, jsId, 'mock_captcha_token');
    }
  }

  /// Resolves the calling plugin from the bridge payload's capability token.
  ///
  /// Returns null when the call carries no token or an unknown one — a call
  /// from outside any plugin IIFE, or from a plugin that has been unloaded.
  PluginBridgeIdentity? _identityFor(Map<String, dynamic> parsed) {
    final token = parsed[kBridgeTokenField];
    if (token is! String) return null;
    return _bridgeTokens[token];
  }

  /// Refuses a storage/preference call that cannot be attributed to a plugin.
  ///
  /// Reads answer null and writes are dropped. The alternative — falling back
  /// to a flat, shared key space — is what made the per-plugin namespace a
  /// label rather than a boundary. Audit W12.
  void _denyUnattributed(String channel, int bid, String? jsId) {
    talker.warning(
      '[bridge] $channel refused: call carries no plugin capability token',
    );
    if (kDebugMode) {
      debugPrint('[bridge] $channel refused — unattributed plugin call');
    }
    if (jsId != null) _reply(bid, jsId, null);
  }

  // ── HTTP bridge ───────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _handleHttp(
    String argsJson, {
    CancelToken? cancelToken,
    // Calling plugin's namespace, threaded through so the CF bypass can
    // scope its WebView cache per plugin. Audit H6 / PR-08d.
    String? callerNamespace,
  }) async {
    final requestId =
        'req_${DateTime.now().microsecondsSinceEpoch.toString().substring(10)}';
    try {
      final req = jsonDecode(argsJson) as Map<String, dynamic>;
      final method = (req['method'] as String?) ?? 'GET';
      final url = req['url'] as String;
      final rawHeaders = req['headers'];
      final body = req['body'];

      final headers = rawHeaders != null
          ? Map<String, dynamic>.from(rawHeaders as Map)
          : <String, dynamic>{};
      if (!headers.keys.any((k) => k.toLowerCase() == 'user-agent')) {
        // Must be the same UA playback will use: CDNs routinely tie a signed
        // URL to the requesting agent, so resolving as one browser and playing
        // as another 403s. See http_defaults.dart.
        headers['User-Agent'] = kDefaultBrowserUserAgent;
      }
      if (!headers.keys.any((k) => k.toLowerCase() == 'accept-encoding')) {
        headers['Accept-Encoding'] = 'identity';
      }

      final contentTypeKey = headers.keys.firstWhere(
        (k) => k.toLowerCase() == 'content-type',
        orElse: () => '',
      );
      String? contentType;
      if (contentTypeKey.isNotEmpty) {
        contentType = headers[contentTypeKey] as String;
      } else if (method == 'POST' || method == 'PUT') {
        contentType = 'application/x-www-form-urlencoded';
        headers['Content-Type'] = contentType;
      }

      talker.debug('[JS HTTP] $method $url ($requestId)');

      final response = await fetchCappedPlainBody(
        _dio,
        url,
        data: body,
        cancelToken: cancelToken,
        options: Options(
          method: method,
          headers: headers,
          contentType: contentType,
          validateStatus: (_) => true,
          followRedirects: true,
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
        ),
      );

      final responseHeaders = response.headers.map.map<String, dynamic>(
        (k, v) =>
            MapEntry(k, k.toLowerCase() == 'set-cookie' ? v : v.join(',')),
      );
      final responseBody = response.body;

      talker.debug('[JS HTTP] Back $url ($requestId) → ${response.statusCode}');

      if (CloudflareBypass.instance.isCloudflareChallenge(
        response.statusCode,
        responseHeaders,
        responseBody,
      )) {
        talker.debug('[JS HTTP] Cloudflare challenge detected ($requestId)');
        if (cancelToken != null && cancelToken.isCancelled) {
          return {
            'code': 0,
            'statusCode': 0,
            'status': 0,
            'body': '',
            'error': 'cancelled',
          };
        }
        final cfResult = await CloudflareBypass.instance.solveAndFetch(
          url,
          callerId: callerNamespace,
          onSolved: (host) => _injectCfCookies(host),
        );
        if (cfResult != null) {
          talker.debug('[JS HTTP] Cloudflare solved ($requestId)');
          return {
            'code': cfResult.statusCode,
            'statusCode': cfResult.statusCode,
            'status': cfResult.statusCode,
            'body': cfResult.body,
            'headers': <String, String>{},
            'finalUrl': cfResult.finalUrl,
          };
        } else {
          talker.error('[JS HTTP] Cloudflare solve failed ($requestId)');
        }
      }

      return {
        'code': response.statusCode,
        'statusCode': response.statusCode,
        'status': response.statusCode,
        'body': responseBody,
        'headers': responseHeaders,
        'finalUrl': response.realUri.toString(),
      };
    } catch (e) {
      if (kDebugMode) debugPrint('[JS HTTP ERROR] $requestId: $e');
      talker.error('[JS HTTP ERROR] $requestId: $e');
      return {
        'code': 0,
        'statusCode': 0,
        'status': 0,
        'body': '',
        'error': e.toString(),
      };
    }
  }

  Future<void> _injectCfCookies(String host) async {
    try {
      final mgr = wv.CookieManager.instance();
      final webCookies = await mgr.getCookies(url: wv.WebUri('https://$host/'));
      if (webCookies.isEmpty) return;
      final uri = Uri.parse('https://$host/');
      final ioCookies = webCookies
          .where(
            (c) =>
                c.name == 'cf_clearance' ||
                c.name == '__cf_bm' ||
                c.name.toString().startsWith('__cf'),
          )
          .map((c) {
            final cookie = io.Cookie(
              c.name.toString(),
              (c.value as String?) ?? '',
            );
            cookie.domain = c.domain ?? host;
            cookie.path = c.path ?? '/';
            cookie.httpOnly = c.isHttpOnly ?? false;
            cookie.secure = c.isSecure ?? false;
            if (c.expiresDate != null) {
              cookie.expires = DateTime.fromMillisecondsSinceEpoch(
                c.expiresDate!.toInt(),
              );
            }
            return cookie;
          })
          .toList();
      if (_cookieJarReady) await _cookieJar.saveFromResponse(uri, ioCookies);
      if (kDebugMode) {
        debugPrint(
          '[CF Cookie] Injected ${ioCookies.length} cookies for $host',
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[CF Cookie] Injection error for $host: $e');
    }
  }

  // ── Public API ────────────────────────────────────────────────────────────

  Future<void> loadScript(String script, {String? tag}) async {
    await _workerReady.future;
    final id = _nextId++;
    final c = Completer<void>();
    _pendingLoads[id] = c;
    _workerPort.send({
      _mLoadScript: 1,
      'id': id,
      'payload': script,
      'tag': tag,
    });
    return c.future;
  }

  Future<void> loadBytes(Uint8List bytecode, {String? tag}) async {
    await _workerReady.future;
    final id = _nextId++;
    final c = Completer<void>();
    _pendingLoads[id] = c;
    _workerPort.send({
      _mLoadBytes: 1,
      'id': id,
      'payload': bytecode,
      'tag': tag,
    });
    return c.future;
  }

  // ── Bridge capability tokens (audit W12) ──────────────────────────────────

  /// Payload field a plugin echoes its capability token back in.
  static const String kBridgeTokenField = '__ssTok';

  /// Prefix of the per-plugin, one-shot installer function the plugin wrapper
  /// publishes on globalThis. Dart calls `<prefix><namespace>(token)` in a
  /// one-line eval right after the wrapper loads, so the token is an argument
  /// to that plugin's own installer and never sits in a slot shared with
  /// another plugin. See `JsBasedProvider._buildIife`.
  static const String kBridgeInstallerPrefix = '__ssInstall_';

  /// Mints (or returns the existing) capability token for [namespace].
  ///
  /// The token is a fresh 192-bit random value per app run, so it is not
  /// guessable and it is not stored in the plugin's cached bytecode.
  String mintBridgeToken({
    required String namespace,
    required String packageName,
  }) {
    final existing = _tokensByNamespace[namespace];
    if (existing != null) return existing;
    final rnd = Random.secure();
    final token = base64Url.encode(
      List<int>.generate(24, (_) => rnd.nextInt(256)),
    );
    _bridgeTokens[token] = PluginBridgeIdentity(
      rawNamespace: namespace,
      storageNamespace: _getCleanNamespace(namespace)!,
      packageName: packageName,
    );
    _tokensByNamespace[namespace] = token;
    return token;
  }

  /// Resolves a token the way the bridge does. Test seam.
  @visibleForTesting
  PluginBridgeIdentity? identityForToken(String token) => _bridgeTokens[token];

  void _revokeBridgeToken(String namespace) {
    final token = _tokensByNamespace.remove(namespace);
    if (token != null) _bridgeTokens.remove(token);
  }

  // ── Per-invocation HTTP cancellation (audit W12) ──────────────────────────

  CancelToken _acquireHttpToken(String? scope) {
    final token = CancelToken();
    if (scope != null) (_httpScopes[scope] ??= <CancelToken>{}).add(token);
    return token;
  }

  void _releaseHttpToken(String? scope, CancelToken token) {
    if (scope == null) return;
    final live = _httpScopes[scope];
    if (live == null) return;
    live.remove(token);
    if (live.isEmpty) _httpScopes.remove(scope);
  }

  void _cancelHttpForScope(String scope, String reason) {
    final live = _httpScopes.remove(scope);
    if (live == null) return;
    for (final token in live) {
      if (!token.isCancelled) token.cancel(reason);
    }
  }

  /// Drops all bookkeeping for invocation [id] and, when it was the last
  /// invocation outstanding for its namespace, cancels that namespace's
  /// in-flight plugin HTTP. Idempotent — the worker's result message and
  /// [invokeAsync]'s own cleanup both land here.
  void _retireInvoke(int id, {String? cancelReason}) {
    final token = _cancelTokens.remove(id);
    if (cancelReason != null && token != null && !token.isCancelled) {
      token.cancel(cancelReason);
    }
    final namespace = _invokeNamespaces.remove(id);
    if (namespace == null) return;
    final remaining = (_outstandingInvokes[namespace] ?? 1) - 1;
    if (remaining > 0) {
      _outstandingInvokes[namespace] = remaining;
      return;
    }
    _outstandingInvokes.remove(namespace);
    _cancelHttpForScope(namespace, 'invocation finished: $namespace');
  }

  Future<dynamic> invokeAsync(
    String functionName, [
    List<dynamic>? args,
    CancelToken? externalCancelToken,
  ]) async {
    await _workerReady.future;

    final argsJson = args != null && args.isNotEmpty
        ? '[${args.map(jsonEncode).join(', ')}]'
        : '[]';

    final id = _nextId++;
    final invokeCompleter = Completer<dynamic>();
    final cancelToken = externalCancelToken ?? CancelToken();

    _pendingInvokes[id] = invokeCompleter;
    _cancelTokens[id] = cancelToken;
    // The calling plugin's namespace comes from the function name Dart itself
    // built ("$ns.search"), so it is authoritative. It is the cancellation
    // scope for any HTTP this invocation sets off. Audit W12 / PR-08b.
    final dotIdx = functionName.indexOf('.');
    final namespace = dotIdx > 0 ? functionName.substring(0, dotIdx) : null;
    if (namespace != null) {
      _invokeNamespaces[id] = namespace;
      _outstandingInvokes[namespace] =
          (_outstandingInvokes[namespace] ?? 0) + 1;
      // The caller abandoning the search (search-as-you-type, backing out of
      // the screen) has to reach the plugin's sockets, not just this future.
      unawaited(
        cancelToken.whenCancel.then((_) {
          _cancelHttpForScope(namespace, 'caller cancelled: $functionName');
        }),
      );
    }

    _workerPort.send({
      _mInvoke: 1,
      'id': id,
      'fn': functionName,
      'aj': argsJson,
    });

    dynamic result;
    try {
      result = await invokeCompleter.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () {
          _pendingInvokes.remove(id);
          _retireInvoke(id, cancelReason: 'invokeAsync timeout: $functionName');
          _workerPort.send({_mCancelInvoke: 1, 'id': id});
          throw TimeoutException('Timeout executing $functionName');
        },
      );
      _retireInvoke(id);
    } catch (e) {
      _retireInvoke(id);
      rethrow;
    }

    // ── Post-processing (mirrors the old logic) ───────────────────────────
    final isManifest = functionName.endsWith('getManifest');
    dynamic unwrapped;

    if (result is String) {
      if (result == '__dart_void__') {
        unwrapped = null;
      } else {
        try {
          unwrapped = jsonDecode(result);
        } catch (_) {
          unwrapped = result;
        }
      }
    } else {
      unwrapped = result;
    }

    if (!isManifest && unwrapped is Map) {
      final success = (unwrapped['success'] ?? false) as bool;
      if (!success) {
        final code = (unwrapped['errorCode'] ?? 'UNKNOWN_ERROR') as String;
        final message =
            (unwrapped['message'] ?? 'An unexpected plugin error occurred')
                as String;
        throw JsPluginException(code, message);
      }
      return unwrapped['data'];
    }
    return unwrapped;
  }

  Future<dynamic> callFunction(String name, [List<dynamic>? args]) =>
      invokeAsync(name, args);

  void cancelPendingForTag(String tag) {
    _workerPort.send({_mCancelTag: tag});
  }

  /// Removes a plugin's exports from the shared JS runtime. Each plugin
  /// IIFE assigns its API to `globalThis[namespace]`, so deleting the
  /// global slot drops the plugin's closures and lets the next GC reclaim
  /// memory. Also cancels any pending evals tagged with the namespace so
  /// in-flight work for the unloaded plugin doesn't race with reload.
  ///
  /// Audit H9 — was a TODO commented out in extension_manager because the
  /// engine had no unload API. Now provided.
  void unload(String namespace) {
    if (namespace.isEmpty) return;
    // Drop queued evals for this plugin first; they'd run on a globalThis
    // slot that's about to vanish.
    _workerPort.send({_mCancelTag: namespace});
    _workerPort.send({_mUnload: namespace});
    // Anything the unloaded plugin still has on the wire, and its capability
    // token: a reload mints a fresh one. Audit W12.
    _cancelHttpForScope(namespace, 'plugin unloaded: $namespace');
    _revokeBridgeToken(namespace);
  }

  Future<List<io.Cookie>> getCookiesForUri(Uri uri) async {
    if (!_cookieJarReady) return [];
    return await _cookieJar.loadForRequest(uri);
  }

  /// `com_foo_bar__sub1` → `com_foo_bar`. Sub-providers of one plugin share
  /// one storage key space.
  String? _getCleanNamespace(String? ns) {
    if (ns == null) return null;
    return ns.contains('__') ? ns.split('__')[0] : ns;
  }

  void dispose() {
    for (final entry in _cancelTokens.entries) {
      if (!entry.value.isCancelled) entry.value.cancel('engine disposed');
    }
    _cancelTokens.clear();
    _invokeNamespaces.clear();
    _outstandingInvokes.clear();
    for (final scope in _httpScopes.keys.toList()) {
      _cancelHttpForScope(scope, 'engine disposed');
    }
    _httpScopes.clear();
    _bridgeTokens.clear();
    _tokensByNamespace.clear();
    try {
      _workerPort.send({_mDispose: 1});
    } catch (_) {}
    _rx.close();
    _isolate?.kill(priority: Isolate.immediate);
    _pendingLoads.clear();
    _pendingInvokes.clear();
  }

  void runGC() {
    _workerPort.send({_mGc: 1});
  }
}

class CfOnlyCookieInterceptor extends Interceptor {
  final CookieJar jar;
  CfOnlyCookieInterceptor(this.jar);

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final uri = Uri.parse(options.uri.toString());
    List<io.Cookie> cookies = [];
    try {
      cookies = await jar.loadForRequest(uri);
    } catch (_) {}

    final cfCookies = cookies
        .where(
          (c) =>
              c.name == 'cf_clearance' ||
              c.name == '__cf_bm' ||
              c.name.startsWith('__cf'),
        )
        .toList();

    String? manualCookie;
    options.headers.forEach((key, value) {
      if (key.toLowerCase() == 'cookie') {
        manualCookie = value?.toString();
      }
    });

    if (cfCookies.isNotEmpty) {
      final cfCookieStr = cfCookies
          .map((c) => '${c.name}=${c.value}')
          .join('; ');
      if (manualCookie != null && manualCookie!.isNotEmpty) {
        final Map<String, String> merged = {};
        for (final pair in cfCookieStr.split(';')) {
          final parts = pair.split('=');
          if (parts.length >= 2) {
            merged[parts[0].trim()] = parts.sublist(1).join('=').trim();
          }
        }
        for (final pair in manualCookie!.split(';')) {
          final parts = pair.split('=');
          if (parts.length >= 2) {
            merged[parts[0].trim()] = parts.sublist(1).join('=').trim();
          }
        }
        final finalCookieStr = merged.entries
            .map((e) => '${e.key}=${e.value}')
            .join('; ');
        options.headers['Cookie'] = finalCookieStr;
      } else {
        options.headers['Cookie'] = cfCookieStr;
      }
    } else if (manualCookie != null) {
      options.headers['Cookie'] = manualCookie;
    }

    handler.next(options);
  }

  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    final rawCookies = response.headers['set-cookie'];
    if (rawCookies != null && rawCookies.isNotEmpty) {
      final uri = Uri.parse(response.realUri.toString());
      final List<io.Cookie> ioCookies = [];
      for (final header in rawCookies) {
        try {
          final cookie = io.Cookie.fromSetCookieValue(header);
          if (cookie.name == 'cf_clearance' ||
              cookie.name == '__cf_bm' ||
              cookie.name.startsWith('__cf')) {
            ioCookies.add(cookie);
          }
        } catch (_) {}
      }
      if (ioCookies.isNotEmpty) {
        try {
          await jar.saveFromResponse(uri, ioCookies);
        } catch (_) {}
      }
    }
    handler.next(response);
  }
}

/// Builds the `_mBridgeResp` message that carries a bridge result back to the
/// worker isolate.
///
/// The result is placed in the message *unencoded*. The worker calls
/// `jsonEncode` on it before splicing it into the `_resolveDartAsync` eval, so
/// the cost of serialising a large scraped page lands on the worker isolate
/// and not on the one that draws the UI. Audit W24.
@visibleForTesting
Map<String, Object?> buildBridgeResponse({
  required int bid,
  required String jsId,
  required Object? result,
  bool isError = false,
}) => <String, Object?>{
  _mBridgeResp: 1,
  'bid': bid,
  'jsId': jsId,
  _kBridgeRespValue: result,
  'err': isError,
};

// ── Message type keys (must match js_engine_worker.dart) ─────────────────────
// Main → Worker
const _mLoadScript = 'ls';
const _mLoadBytes = 'lb';
const _mInvoke = 'iv';
const _mCancelInvoke = 'ci';
const _mCancelTag = 'ct';
const _mBridgeResp = 'br';
// Raw (unencoded) bridge result — see buildBridgeResponse.
const _kBridgeRespValue = 'rv';
const _mDispose = 'dp';
const _mGc = 'gc';
const _mUnload = 'ul'; // {ul: String namespace}

// Worker → Main
const _mReady = 'rd';
const _mLoadDone = 'ld';
const _mLoadErr = 'le';
const _mInvokeResult = 'ir';
const _mBridge = 'bg';
const _mLog = 'll';
