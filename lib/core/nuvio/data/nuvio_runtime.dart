import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../network/dio_client_provider.dart';
import '../models/nuvio_models.dart';

part 'nuvio_runtime.g.dart';

@Riverpod(keepAlive: true)
NuvioRuntime nuvioRuntime(Ref ref) => NuvioRuntime(ref.watch(dioClientProvider));

/// Runs Nuvio scraper plugins.
///
/// Nuvio wraps a scraper in `module/exports`, then calls
/// `getStreams(tmdbId, mediaType, season, episode)` and JSON-serialises the
/// result. SkyStream does the same on QuickJS, with a small host environment:
/// `fetch` (backed by Dio, so it inherits the app's TLS/DoH/UA setup),
/// `console`, `btoa`/`atob`, `URLSearchParams`, timers and `AbortController`.
///
/// Scrapers that need a DOM (cheerio) or WebAssembly are rejected with a clear
/// message instead of failing silently — everything else, which is the vast
/// majority (fetch + regex + JSON), runs unchanged.
class NuvioRuntime {
  NuvioRuntime(this._dio);

  final Dio _dio;

  static const Duration defaultTimeout = Duration(seconds: 45);
  static const int _maxResponseChars = 4 * 1024 * 1024;

  /// Quick static check so an unsupported scraper reports why.
  static String? unsupportedReason(String code) {
    if (RegExp(r'''require\(\s*['"]cheerio['"]''').hasMatch(code)) {
      return 'Needs cheerio (HTML DOM), which SkyStream does not expose yet.';
    }
    if (code.contains('WebAssembly')) {
      return 'Needs WebAssembly, which SkyStream does not expose yet.';
    }
    return null;
  }

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
    final blocked = unsupportedReason(code);
    if (blocked != null) throw NuvioRuntimeException(blocked);

    final runtime = getJavascriptRuntime(
      xhr: false,
      extraArgs: {
        'stackSize': 2 * 1024 * 1024,
        'memoryLimit': 192 * 1024 * 1024,
      },
    );

    final completer = Completer<String>();
    final pending = <String, bool>{};
    Timer? pump;

    void evalSafe(String script) {
      try {
        runtime.evaluate(script);
      } catch (error) {
        if (kDebugMode) debugPrint('[Nuvio] eval failed: $error');
      }
    }

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

      runtime.onMessage('nuvio_fetch', (dynamic args) {
        final data = args is Map
            ? Map<String, dynamic>.from(args)
            : jsonDecode(args.toString()) as Map<String, dynamic>;
        final id = data['id']?.toString();
        if (id == null) return null;
        pending[id] = true;
        unawaited(_performFetch(data, evalSafe, () => pending.remove(id)));
        return null;
      });

      // Promise jobs only advance when QuickJS is pumped.
      pump = Timer.periodic(const Duration(milliseconds: 12), (_) {
        try {
          runtime.executePendingJob();
        } catch (_) {
          // Ignore: a scraper throwing inside a microtask is its own problem.
        }
      });

      runtime.evaluate(_polyfill(scraperId, jsonEncode(settings)));
      runtime.evaluate('''
        var module = { exports: {} };
        var exports = module.exports;
        (function() {
          $code
        })();
      ''');

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
        onTimeout: () => jsonEncode({'error': 'Timed out after ${timeout.inSeconds}s'}),
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
      try {
        runtime.dispose();
      } catch (_) {
        // Disposal races with in-flight jobs on some platforms; harmless.
      }
    }
  }

  Future<void> _performFetch(
    Map<String, dynamic> data,
    void Function(String script) evalSafe,
    void Function() done,
  ) async {
    final id = data['id'].toString();
    final url = data['url']?.toString() ?? '';
    final method = (data['method']?.toString() ?? 'GET').toUpperCase();
    final body = data['body']?.toString();
    final headers = <String, String>{};
    final rawHeaders = data['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        if (key is String && value != null) headers[key] = value.toString();
      });
    }

    try {
      final response = await _dio.request<dynamic>(
        url,
        data: body,
        options: Options(
          method: method,
          headers: headers,
          responseType: ResponseType.plain,
          followRedirects: true,
          receiveTimeout: const Duration(seconds: 25),
          sendTimeout: const Duration(seconds: 25),
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
        if (values.isNotEmpty) responseHeaders[key] = values.first;
      });

      final payload = jsonEncode({
        'ok': (response.statusCode ?? 0) >= 200 && (response.statusCode ?? 0) < 300,
        'status': response.statusCode ?? 0,
        'url': response.realUri.toString(),
        'headers': responseHeaders,
        'body': text,
      });
      evalSafe('globalThis.__nuvio_settle(${jsonEncode(id)}, $payload, null)');
    } catch (error) {
      evalSafe(
        'globalThis.__nuvio_settle(${jsonEncode(id)}, null, ${jsonEncode(error.toString())})',
      );
    } finally {
      done();
    }
  }

  /// Minimal browser-ish environment Nuvio scrapers expect.
  String _polyfill(String scraperId, String settingsJson) => '''
    globalThis.__nuvio_pending = {};
    globalThis.__nuvio_seq = 0;

    globalThis.__nuvio_result = function (payload) {
      sendMessage('nuvio_result', payload);
    };

    globalThis.__nuvio_settle = function (id, payload, error) {
      var entry = globalThis.__nuvio_pending[id];
      if (!entry) return;
      delete globalThis.__nuvio_pending[id];
      if (error) { entry.reject(new Error(error)); return; }
      entry.resolve(payload);
    };

    var console = {
      log: function () { sendMessage('nuvio_log', Array.prototype.join.call(arguments, ' ')); },
      warn: function () { sendMessage('nuvio_log', 'WARN ' + Array.prototype.join.call(arguments, ' ')); },
      error: function () { sendMessage('nuvio_log', 'ERROR ' + Array.prototype.join.call(arguments, ' ')); },
      debug: function () {},
      info: function () { sendMessage('nuvio_log', Array.prototype.join.call(arguments, ' ')); }
    };
    globalThis.console = console;

    globalThis.NUVIO_SCRAPER_ID = $scraperId;
    globalThis.NUVIO_SETTINGS = $settingsJson;
    globalThis.getScraperSetting = function (key, fallback) {
      var settings = globalThis.NUVIO_SETTINGS || {};
      return settings[key] !== undefined ? settings[key] : fallback;
    };

    function NuvioHeaders(map) {
      this._map = {};
      for (var key in (map || {})) {
        this._map[String(key).toLowerCase()] = map[key];
      }
    }
    NuvioHeaders.prototype.get = function (name) {
      var value = this._map[String(name).toLowerCase()];
      return value === undefined ? null : value;
    };
    NuvioHeaders.prototype.has = function (name) {
      return this._map[String(name).toLowerCase()] !== undefined;
    };
    NuvioHeaders.prototype.forEach = function (fn) {
      var self = this;
      Object.keys(this._map).forEach(function (k) { fn(self._map[k], k); });
    };
    globalThis.Headers = NuvioHeaders;

    function NuvioResponse(raw) {
      this.ok = !!raw.ok;
      this.status = raw.status;
      this.statusText = String(raw.status);
      this.url = raw.url;
      this.headers = new NuvioHeaders(raw.headers || {});
      this._body = raw.body || '';
      this.bodyUsed = false;
      this.redirected = false;
      this.type = 'basic';
    }
    NuvioResponse.prototype.text = function () {
      this.bodyUsed = true;
      return Promise.resolve(this._body);
    };
    NuvioResponse.prototype.json = function () {
      var body = this._body;
      return new Promise(function (resolve, reject) {
        try { resolve(JSON.parse(body)); } catch (e) { reject(e); }
      });
    };
    NuvioResponse.prototype.clone = function () { return this; };

    globalThis.fetch = function (input, init) {
      init = init || {};
      var url = (typeof input === 'string') ? input : (input && input.url);
      var id = 'f' + (++globalThis.__nuvio_seq);

      var headers = {};
      var rawHeaders = init.headers || (input && input.headers) || {};
      if (rawHeaders && typeof rawHeaders.forEach === 'function' && !Array.isArray(rawHeaders)) {
        rawHeaders.forEach(function (value, key) { headers[key] = value; });
      } else {
        for (var key in rawHeaders) { headers[key] = rawHeaders[key]; }
      }

      var body = init.body;
      if (body && typeof body !== 'string') {
        try { body = JSON.stringify(body); } catch (e) { body = String(body); }
      }

      return new Promise(function (resolve, reject) {
        globalThis.__nuvio_pending[id] = {
          resolve: function (payload) { resolve(new NuvioResponse(payload)); },
          reject: reject
        };
        sendMessage('nuvio_fetch', JSON.stringify({
          id: id,
          url: url,
          method: (init.method || 'GET'),
          headers: headers,
          body: body || null
        }));
      });
    };

    globalThis.AbortController = function () {
      this.signal = { aborted: false, addEventListener: function () {} };
      this.abort = function () { this.signal.aborted = true; };
    };

    globalThis.btoa = function (input) {
      var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
      var str = String(input), output = '';
      for (var block = 0, charCode, i = 0, map = chars;
           str.charAt(i | 0) || (map = '=', i % 1);
           output += map.charAt(63 & (block >> (8 - (i % 1) * 8)))) {
        charCode = str.charCodeAt((i += 3 / 4));
        block = block << 8 | charCode;
      }
      return output;
    };
    globalThis.atob = function (input) {
      var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
      var str = String(input).replace(/=+\$/, ''), output = '';
      for (var bc = 0, bs = 0, buffer, i = 0;
           (buffer = str.charAt(i++));
           ~buffer && (bs = bc % 4 ? bs * 64 + buffer : buffer, bc++ % 4)
             ? output += String.fromCharCode(255 & bs >> (-2 * bc & 6)) : 0) {
        buffer = chars.indexOf(buffer);
      }
      return output;
    };

    function NuvioSearchParams(init) {
      this._pairs = [];
      if (typeof init === 'string') {
        init.replace(/^\\?/, '').split('&').forEach(function (pair) {
          if (!pair) return;
          var idx = pair.indexOf('=');
          var k = idx < 0 ? pair : pair.slice(0, idx);
          var v = idx < 0 ? '' : pair.slice(idx + 1);
          this._pairs.push([decodeURIComponent(k), decodeURIComponent(v)]);
        }, this);
      } else if (init && typeof init === 'object') {
        for (var key in init) this._pairs.push([key, String(init[key])]);
      }
    }
    NuvioSearchParams.prototype.append = function (k, v) { this._pairs.push([k, String(v)]); };
    NuvioSearchParams.prototype.set = NuvioSearchParams.prototype.append;
    NuvioSearchParams.prototype.get = function (k) {
      for (var i = 0; i < this._pairs.length; i++) {
        if (this._pairs[i][0] === k) return this._pairs[i][1];
      }
      return null;
    };
    NuvioSearchParams.prototype.toString = function () {
      return this._pairs.map(function (p) {
        return encodeURIComponent(p[0]) + '=' + encodeURIComponent(p[1]);
      }).join('&');
    };
    globalThis.URLSearchParams = NuvioSearchParams;
  ''';
}

class NuvioRuntimeException implements Exception {
  final String message;
  const NuvioRuntimeException(this.message);
  @override
  String toString() => message;
}
