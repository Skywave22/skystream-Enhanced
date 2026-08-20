import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../network/dio_client_provider.dart';
import '../models/nuvio_models.dart';
import 'nuvio_crypto.dart';
import 'nuvio_dom.dart';
import 'nuvio_polyfill.dart';
import 'nuvio_tmdb.dart';

part 'nuvio_runtime.g.dart';

@Riverpod(keepAlive: true)
NuvioRuntime nuvioRuntime(Ref ref) => NuvioRuntime(
  ref.watch(dioClientProvider),
  () => ref.read(effectiveNuvioTmdbKeyProvider),
);

/// Runs Nuvio scraper plugins.
///
/// Nuvio wraps a scraper in `module/exports`, then calls
/// `getStreams(tmdbId, mediaType, season, episode)` and JSON-serialises the
/// result. SkyStream does the same on QuickJS, behind the environment in
/// [nuvioPolyfillSource]: fetch/XHR (Dio-backed, so DoH/TLS/UA are the app's),
/// timers, URL, Buffer, TextEncoder, WebCrypto + CryptoJS, localStorage,
/// cheerio and `require`.
class NuvioRuntime {
  NuvioRuntime(this._dio, this._tmdbKey);

  final Dio _dio;

  /// Scrapers call TMDB themselves; they get the key from the Nuvio tab.
  final String Function() _tmdbKey;

  /// Matches Nuvio's own per-plugin budget. Scrapers chain 3–5 requests
  /// through slow mirrors; anything shorter silently drops working providers.
  static const Duration defaultTimeout = Duration(seconds: 60);
  static const int _maxResponseChars = 8 * 1024 * 1024;
  static const String _defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// Static gate for things the runtime genuinely cannot do. Kept deliberately
  /// empty: an earlier version rejected any file whose text contained
  /// "WebAssembly", which threw away bundles that merely *mention* it in dead
  /// polyfill branches. Real failures are reported per scraper instead.
  static String? unsupportedReason(String code) => null;

  Future<List<NuvioStreamResult>> run({
    required String code,
    required String scraperId,
    required String scraperName,
    required String tmdbId,
    required String mediaType,
    int? season,
    int? episode,
    Map<String, dynamic> settings = const {},
    Duration timeout = defaultTimeout,
  }) async {
    final runtime = getJavascriptRuntime(
      xhr: false,
      extraArgs: {
        'stackSize': 4 * 1024 * 1024,
        'memoryLimit': 192 * 1024 * 1024,
      },
    );

    final completer = Completer<String>();
    final dom = NuvioDom();
    Timer? pump;

    void evalSafe(String script) {
      try {
        runtime.evaluate(script);
      } catch (error) {
        if (kDebugMode) debugPrint('[Nuvio] eval failed: $error');
      }
    }

    Map<String, dynamic> asMap(dynamic args) => args is Map
        ? Map<String, dynamic>.from(args)
        : jsonDecode(args.toString()) as Map<String, dynamic>;

    List<String> asIds(dynamic raw) => <String>[
      if (raw is List)
        for (final id in raw) id.toString(),
    ];

    try {
      runtime.onMessage('nuvio_result', (dynamic args) {
        if (!completer.isCompleted) {
          completer.complete(args is String ? args : jsonEncode(args));
        }
        return null;
      });

      runtime.onMessage('nuvio_log', (dynamic args) {
        if (kDebugMode) debugPrint('[Nuvio:$scraperName] $args');
        return null;
      });

      // --- crypto ---------------------------------------------------------
      runtime.onMessage(
        'nuvio_crypto',
        (dynamic args) => NuvioCrypto.handle(asMap(args)),
      );

      // --- cheerio bridge -------------------------------------------------
      runtime.onMessage('nuvio_dom_load', (dynamic args) {
        return dom.load(asMap(args)['html']?.toString() ?? '');
      });

      runtime.onMessage('nuvio_dom_query', (dynamic args) {
        final data = asMap(args);
        return jsonEncode(
          dom.query(
            data['doc']?.toString() ?? '',
            data['context']?.toString(),
            data['selector']?.toString() ?? '',
          ),
        );
      });

      runtime.onMessage('nuvio_dom_filter', (dynamic args) {
        final data = asMap(args);
        return jsonEncode(
          dom.filter(
            data['doc']?.toString() ?? '',
            asIds(data['nodes']),
            data['selector']?.toString() ?? '',
          ),
        );
      });

      runtime.onMessage('nuvio_dom_relation', (dynamic args) {
        final data = asMap(args);
        return jsonEncode(
          dom.relation(
            data['doc']?.toString() ?? '',
            asIds(data['nodes']),
            data['kind']?.toString() ?? '',
            data['selector']?.toString(),
          ),
        );
      });

      runtime.onMessage('nuvio_dom_describe', (dynamic args) {
        final data = asMap(args);
        return dom.describeBatch(
          data['doc']?.toString() ?? '',
          asIds(data['nodes']),
        );
      });

      runtime.onMessage('nuvio_dom_text', (dynamic args) {
        final data = asMap(args);
        return dom.textOf(data['doc']?.toString() ?? '', asIds(data['nodes']));
      });

      runtime.onMessage('nuvio_dom_html', (dynamic args) {
        final data = asMap(args);
        return dom.html(
          data['doc']?.toString() ?? '',
          data['node']?.toString() ?? '',
        );
      });

      runtime.onMessage('nuvio_dom_attr', (dynamic args) {
        final data = asMap(args);
        return dom.attr(
              data['doc']?.toString() ?? '',
              data['node']?.toString() ?? '',
              data['name']?.toString() ?? '',
            ) ??
            '';
      });

      runtime.onMessage('nuvio_fetch', (dynamic args) {
        final data = asMap(args);
        final id = data['id']?.toString();
        if (id == null) return null;
        unawaited(_performFetch(data, evalSafe));
        return null;
      });

      // Promise jobs and timers only advance when QuickJS is pumped. Jobs are
      // drained often; timers are checked every ~32 ms, which is plenty for
      // the retry/rate-limit sleeps scrapers use and keeps ten parallel
      // contexts from burning CPU on bridge calls.
      var tickCounter = 0;
      pump = Timer.periodic(const Duration(milliseconds: 8), (_) {
        try {
          runtime.executePendingJob();
          if (++tickCounter % 4 == 0) {
            runtime.evaluate('__nuvio_tick && __nuvio_tick();');
          }
        } catch (_) {
          // A scraper throwing inside a microtask is its own problem.
        }
      });

      runtime.evaluate(
        buildNuvioPolyfill(
          scraperIdJson: jsonEncode(scraperId),
          settingsJson: jsonEncode(settings),
          tmdbKeyJson: jsonEncode(_tmdbKey()),
        ),
      );
      runtime.evaluate(_wrapScraper(code));

      final seasonArg = season?.toString() ?? 'undefined';
      final episodeArg = episode?.toString() ?? 'undefined';
      runtime.evaluate('''
        (async function () {
          try {
            var getStreams = (module.exports && module.exports.getStreams) ||
                globalThis.getStreams;
            if (!getStreams) {
              __nuvio_result(JSON.stringify({ error: 'getStreams not found' }));
              return;
            }
            var out = await getStreams(${jsonEncode(tmdbId)}, ${jsonEncode(mediaType)}, $seasonArg, $episodeArg);
            __nuvio_result(JSON.stringify({ streams: out || [] }));
          } catch (e) {
            __nuvio_result(JSON.stringify({
              error: (e && e.message) ? e.message : String(e),
            }));
          }
        })();
      ''');

      final raw = await completer.future.timeout(
        timeout,
        onTimeout: () =>
            jsonEncode({'error': 'Timed out after ${timeout.inSeconds}s'}),
      );

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const [];
      final error = decoded['error'];
      if (error != null) throw NuvioRuntimeException(error.toString());

      final streams = decoded['streams'];
      if (streams is! List) return const [];

      final out = <NuvioStreamResult>[];
      for (final entry in streams) {
        if (entry is! Map) continue;
        final result = NuvioStreamResult.fromJson(
          Map<String, dynamic>.from(entry),
          scraperId: scraperId,
          scraperName: scraperName,
        );
        if (result != null) out.add(result);
      }
      return out;
    } finally {
      pump?.cancel();
      dom.clear();
      try {
        runtime.dispose();
      } catch (_) {
        // Disposal races with in-flight jobs on some platforms; harmless.
      }
    }
  }

  /// Runs a scraper's `onSettings()` and returns the form it describes.
  ///
  /// Nuvio plugins ship their own settings UI as JSON (`header`, `info`,
  /// `text`, `select`, `toggle`); 54 of the 61 providers in All-in-One-Nuvio
  /// declare `hasSettings: true`, and several of them (debrid keys, language,
  /// quality caps, proxies) return nothing useful until they are filled in.
  Future<List<NuvioSettingsField>> settingsLayout({
    required String code,
    required String scraperId,
    Map<String, dynamic> settings = const {},
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final runtime = getJavascriptRuntime(
      xhr: false,
      extraArgs: {
        'stackSize': 4 * 1024 * 1024,
        'memoryLimit': 128 * 1024 * 1024,
      },
    );
    final completer = Completer<String>();
    final dom = NuvioDom();
    Timer? pump;

    void evalSafe(String script) {
      try {
        runtime.evaluate(script);
      } catch (error) {
        if (kDebugMode) debugPrint('[Nuvio] settings eval failed: $error');
      }
    }

    Map<String, dynamic> asMap(dynamic args) => args is Map
        ? Map<String, dynamic>.from(args)
        : jsonDecode(args.toString()) as Map<String, dynamic>;

    try {
      runtime.onMessage('nuvio_result', (dynamic args) {
        if (!completer.isCompleted) {
          completer.complete(args is String ? args : jsonEncode(args));
        }
        return null;
      });
      runtime.onMessage('nuvio_log', (dynamic args) {
        if (kDebugMode) debugPrint('[Nuvio:settings] $args');
        return null;
      });
      runtime.onMessage(
        'nuvio_crypto',
        (dynamic args) => NuvioCrypto.handle(asMap(args)),
      );
      runtime.onMessage('nuvio_dom_load', (dynamic args) {
        return dom.load(asMap(args)['html']?.toString() ?? '');
      });
      runtime.onMessage('nuvio_fetch', (dynamic args) {
        final data = asMap(args);
        if (data['id'] == null) return null;
        unawaited(_performFetch(data, evalSafe));
        return null;
      });

      var tickCounter = 0;
      pump = Timer.periodic(const Duration(milliseconds: 8), (_) {
        try {
          runtime.executePendingJob();
          if (++tickCounter % 4 == 0) {
            runtime.evaluate('__nuvio_tick && __nuvio_tick();');
          }
        } catch (_) {
          // Ignore microtask failures.
        }
      });

      runtime.evaluate(
        buildNuvioPolyfill(
          scraperIdJson: jsonEncode(scraperId),
          settingsJson: jsonEncode(settings),
          tmdbKeyJson: jsonEncode(_tmdbKey()),
        ),
      );
      runtime.evaluate(_wrapScraper(code));
      runtime.evaluate(_settingsCall);

      final raw = await completer.future.timeout(
        timeout,
        onTimeout: () => jsonEncode({'error': 'Timed out reading settings'}),
      );
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const [];
      final error = decoded['error'];
      if (error != null) throw NuvioRuntimeException(error.toString());
      return NuvioSettingsField.parseLayout(decoded['layout']);
    } finally {
      pump?.cancel();
      dom.clear();
      try {
        runtime.dispose();
      } catch (_) {
        // Disposal races with in-flight jobs on some platforms; harmless.
      }
    }
  }

  /// Nuvio wraps every scraper in a CommonJS shell before calling into it.
  static String _wrapScraper(String code) =>
      'var module = { exports: {} };\n'
      'var exports = module.exports;\n'
      '(function() {\n$code\n})();';

  static const String _settingsCall = '''
    (async function () {
      try {
        var onSettings = (module.exports && module.exports.onSettings) ||
            globalThis.onSettings;
        if (typeof onSettings !== 'function') {
          __nuvio_result(JSON.stringify({ layout: [] }));
          return;
        }
        var layout = await onSettings();
        __nuvio_result(JSON.stringify({ layout: layout || [] }));
      } catch (e) {
        __nuvio_result(JSON.stringify({
          error: (e && e.message) ? e.message : String(e),
        }));
      }
    })();
  ''';

  Future<void> _performFetch(
    Map<String, dynamic> data,
    void Function(String script) evalSafe,
  ) async {
    final id = data['id'].toString();
    final url = data['url']?.toString() ?? '';
    final method = (data['method']?.toString() ?? 'GET').toUpperCase();
    final body = data['body']?.toString();
    final follow = data['follow'] != false;
    final headers = <String, String>{};
    final rawHeaders = data['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        if (key is String && value != null) headers[key] = value.toString();
      });
    }
    if (!headers.keys.any((key) => key.toLowerCase() == 'user-agent')) {
      headers['User-Agent'] = _defaultUserAgent;
    }

    try {
      final response = await _dio.request<dynamic>(
        url,
        data: body,
        options: Options(
          method: method,
          headers: headers,
          responseType: ResponseType.plain,
          followRedirects: follow,
          maxRedirects: follow ? 5 : 0,
          receiveTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 30),
          validateStatus: (_) => true,
        ),
      );

      var text = response.data is String
          ? response.data as String
          : jsonEncode(response.data);
      if (text.length > _maxResponseChars) {
        text = text.substring(0, _maxResponseChars);
      }

      final responseHeaders = <String, String>{};
      response.headers.map.forEach((key, values) {
        if (values.isNotEmpty) responseHeaders[key.toLowerCase()] = values.first;
      });

      final status = response.statusCode ?? 0;
      final payload = jsonEncode({
        'ok': status >= 200 && status < 300,
        'status': status,
        'statusText': response.statusMessage ?? '$status',
        'url': response.realUri.toString(),
        'redirected': response.realUri.toString() != url,
        'headers': responseHeaders,
        'body': text,
      });
      evalSafe('globalThis.__nuvio_settle(${jsonEncode(id)}, $payload, null)');
    } catch (error) {
      evalSafe(
        'globalThis.__nuvio_settle(${jsonEncode(id)}, null, '
        '${jsonEncode(error.toString())})',
      );
    }
  }
}

class NuvioRuntimeException implements Exception {
  final String message;
  const NuvioRuntimeException(this.message);
  @override
  String toString() => message;
}
