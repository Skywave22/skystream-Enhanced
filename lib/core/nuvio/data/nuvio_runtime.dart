import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/nuvio_models.dart';
import 'nuvio_engine.dart';
import 'nuvio_isolate_pool.dart';
import 'nuvio_tmdb.dart';

part 'nuvio_runtime.g.dart';

@Riverpod(keepAlive: true)
NuvioRuntime nuvioRuntime(Ref ref) {
  final runtime = NuvioRuntime(() => ref.read(effectiveNuvioTmdbKeyProvider));
  ref.onDispose(runtime.dispose);
  return runtime;
}

/// Runs Nuvio scraper plugins.
///
/// Nuvio wraps a scraper in `module/exports`, then calls
/// `getStreams(tmdbId, mediaType, season, episode)` and JSON-serialises the
/// result. SkyStream does the same on QuickJS, behind the environment in
/// [nuvioPolyfillSource]: fetch/XHR, timers, URL, Buffer, TextEncoder,
/// WebCrypto + CryptoJS, localStorage, cheerio and `require`.
///
/// The JavaScript itself runs on [NuvioIsolatePool] worker isolates, so a
/// 1 MB bundle being parsed can't stutter the UI and slow providers can't
/// starve fast ones.
class NuvioRuntime {
  NuvioRuntime(this._tmdbKey, {NuvioIsolatePool? pool})
    : _pool = pool ?? NuvioIsolatePool();

  /// Scrapers call TMDB themselves; they get the key from the Nuvio tab.
  final String Function() _tmdbKey;
  final NuvioIsolatePool _pool;

  /// Matches Nuvio's own per-plugin budget. Scrapers chain 3–5 requests
  /// through slow mirrors; anything shorter silently drops working providers.
  static const Duration defaultTimeout = Duration(seconds: 60);

  /// Static gate for things the runtime genuinely cannot do. Kept deliberately
  /// empty: an earlier version rejected any file whose text contained
  /// "WebAssembly", which threw away bundles that merely *mention* it in dead
  /// polyfill branches. Real failures are reported per scraper instead.
  static String? unsupportedReason(String code) => null;

  void dispose() => _pool.dispose();

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
    final raw = await _pool.execute(
      NuvioEngineRequest(
        code: code,
        scraperId: scraperId,
        scraperName: scraperName,
        tmdbId: tmdbId,
        mediaType: mediaType,
        season: season,
        episode: episode,
        settings: settings,
        tmdbKey: _tmdbKey(),
        timeoutMs: timeout.inMilliseconds,
      ),
    );

    final decoded = _decode(raw);
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
  }

  /// Runs a scraper's `onSettings()` and returns the form it describes.
  ///
  /// Nuvio plugins ship their own settings UI as JSON (`header`, `info`,
  /// `text`, `select`, `toggle`); several of them (debrid keys, language,
  /// quality caps, proxies) return nothing useful until they are filled in.
  Future<List<NuvioSettingsField>> settingsLayout({
    required String code,
    required String scraperId,
    Map<String, dynamic> settings = const {},
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final raw = await _pool.execute(
      NuvioEngineRequest(
        code: code,
        scraperId: scraperId,
        scraperName: scraperId,
        settings: settings,
        tmdbKey: _tmdbKey(),
        timeoutMs: timeout.inMilliseconds,
        mode: 'settings',
      ),
    );
    final decoded = _decode(raw);
    final error = decoded['error'];
    if (error != null) throw NuvioRuntimeException(error.toString());
    return NuvioSettingsField.parseLayout(decoded['layout']);
  }

  Map<String, dynamic> _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : const {};
    } catch (error) {
      if (kDebugMode) debugPrint('[Nuvio] bad worker payload: $error');
      return {'error': 'Plugin returned an unreadable result'};
    }
  }
}

class NuvioRuntimeException implements Exception {
  final String message;
  const NuvioRuntimeException(this.message);
  @override
  String toString() => message;
}
