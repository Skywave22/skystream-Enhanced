import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/nuvio_models.dart';
import 'nuvio_repository.dart';
import 'nuvio_runtime.dart';
import 'nuvio_tmdb.dart';

part 'nuvio_stream_service.g.dart';

@Riverpod(keepAlive: true)
NuvioStreamService nuvioStreamService(Ref ref) => NuvioStreamService(ref);

enum NuvioScraperOutcome { pending, running, links, empty, failed, unsupported }

class NuvioScraperStatus {
  final String scraperName;
  final NuvioScraperOutcome outcome;
  final int linkCount;
  final String? message;

  const NuvioScraperStatus({
    required this.scraperName,
    required this.outcome,
    this.linkCount = 0,
    this.message,
  });

  String get addonLabel => scraperName;
}

class NuvioProgress {
  final List<NuvioStreamResult> streams;
  final List<NuvioScraperStatus> statuses;
  final int completedCount;
  final int totalCount;
  final bool isLoading;

  const NuvioProgress({
    this.streams = const [],
    this.statuses = const [],
    this.completedCount = 0,
    this.totalCount = 0,
    this.isLoading = false,
  });

  bool get hasWork => totalCount > 0;
}

class _CacheEntry {
  _CacheEntry(this.results) : createdAt = DateTime.now();
  final List<NuvioStreamResult> results;
  final DateTime createdAt;

  bool get isFresh =>
      DateTime.now().difference(createdAt) < NuvioStreamService.cacheTtl;
}

/// Runs every enabled Nuvio scraper for one title and streams results back as
/// they arrive, mirroring how the SkyStream plugin aggregator behaves so both
/// systems can feed one list.
class NuvioStreamService {
  NuvioStreamService(this._ref);

  final Ref _ref;

  /// Nuvio itself launches every scraper at once. A phone can't hold 60 QuickJS
  /// contexts, but three at a time was the reason most providers never got to
  /// answer before the user gave up — ten keeps memory sane and finishes a
  /// 60-scraper repository in roughly the time the slowest six take.
  static const int maxConcurrent = 10;

  /// Repeat visits to the same episode shouldn't re-run 60 scrapers.
  static const Duration cacheTtl = Duration(minutes: 10);

  final Map<String, _CacheEntry> _cache = {};

  void clearCache() => _cache.clear();

  /// Nuvio plugins are written against a *numeric TMDB id*. Feeding them an
  /// `tt…` or `tmdb:123` id is the difference between a provider answering and
  /// silently returning nothing, so normalise (and convert) first.
  Future<String> _normalizeId(String rawId, String type) async {
    var id = rawId.trim();
    if (id.isEmpty) return id;
    if (id.startsWith('tmdb:')) id = id.substring(5);
    if (id.startsWith('tmdb/')) id = id.substring(5);
    id = id.split('/').first;
    // Stremio-style "tt1234:1:2" ids.
    final colon = id.indexOf(':');
    if (colon > 0) id = id.substring(0, colon);
    if (!id.startsWith('tt')) return id;

    try {
      final resolved = await _ref
          .read(nuvioTmdbServiceProvider)
          .tmdbIdForImdbId(id, type: type);
      if (resolved != null && resolved.isNotEmpty) return resolved;
    } catch (error) {
      if (kDebugMode) debugPrint('[Nuvio] imdb→tmdb failed for $id: $error');
    }
    return id;
  }

  Stream<NuvioProgress> resolve({
    required String tmdbId,
    required String mediaType,
    int? season,
    int? episode,
  }) async* {
    final repository = _ref.read(nuvioRepositoryProvider.notifier);
    var state = _ref.read(nuvioRepositoryProvider);
    if (state.isLoading) {
      await repository.load();
      state = _ref.read(nuvioRepositoryProvider);
    }

    final type = NuvioScraperInfo.normalizeType(mediaType);
    final targets = state.activeScrapers
        .where((entry) => entry.scraper.supportsType(type))
        .toList();

    if (tmdbId.trim().isEmpty || targets.isEmpty) {
      yield const NuvioProgress(isLoading: false);
      return;
    }

    final resolvedId = await _normalizeId(tmdbId, type);

    final runtime = _ref.read(nuvioRuntimeProvider);
    final streams = <NuvioStreamResult>[];
    final seen = <String>{};
    final statuses = <String, NuvioScraperStatus>{
      for (final entry in targets)
        entry.scraper.id: NuvioScraperStatus(
          scraperName: entry.scraper.name,
          outcome: NuvioScraperOutcome.pending,
        ),
    };
    var completed = 0;

    final updates = StreamController<NuvioProgress>();

    NuvioProgress snapshot({bool loading = true}) => NuvioProgress(
      streams: List.of(streams),
      statuses: statuses.values.toList(),
      completedCount: completed,
      totalCount: targets.length,
      isLoading: loading,
    );

    String cacheKey(String scraperId) =>
        '$scraperId|$resolvedId|$type|${season ?? ''}|${episode ?? ''}';

    void publish(String scraperId, String name, List<NuvioStreamResult> found) {
      var added = 0;
      for (final result in found) {
        if (!seen.add('$scraperId|${result.url}')) continue;
        streams.add(result);
        added++;
      }
      statuses[scraperId] = NuvioScraperStatus(
        scraperName: name,
        outcome: added > 0
            ? NuvioScraperOutcome.links
            : NuvioScraperOutcome.empty,
        linkCount: added,
        message: added > 0 ? null : 'no links',
      );
    }

    Future<void> runOne(
      ({NuvioRepo repo, NuvioScraperInfo scraper}) entry,
    ) async {
      final scraper = entry.scraper;
      final key = cacheKey(scraper.id);
      final cached = _cache[key];
      if (cached != null && cached.isFresh) {
        publish(scraper.id, scraper.name, cached.results);
        completed++;
        if (!updates.isClosed) updates.add(snapshot());
        return;
      }

      statuses[scraper.id] = NuvioScraperStatus(
        scraperName: scraper.name,
        outcome: NuvioScraperOutcome.running,
      );
      if (!updates.isClosed) updates.add(snapshot());

      try {
        final code = await repository.codeFor(entry.repo, scraper);
        final results = await runtime.run(
          code: code,
          scraperId: scraper.id,
          scraperName: scraper.name,
          tmdbId: resolvedId,
          mediaType: type,
          season: season,
          episode: episode,
        );
        _cache[key] = _CacheEntry(results);
        publish(scraper.id, scraper.name, results);
      } on NuvioRuntimeException catch (error) {
        statuses[scraper.id] = NuvioScraperStatus(
          scraperName: scraper.name,
          outcome: NuvioScraperOutcome.failed,
          message: error.message,
        );
      } catch (error) {
        if (kDebugMode) debugPrint('[Nuvio] ${scraper.name}: $error');
        statuses[scraper.id] = NuvioScraperStatus(
          scraperName: scraper.name,
          outcome: NuvioScraperOutcome.failed,
          message: error.toString(),
        );
      } finally {
        completed++;
        if (!updates.isClosed) updates.add(snapshot());
      }
    }

    unawaited(() async {
      final queue = List.of(targets);
      final workers = List.generate(
        targets.length < maxConcurrent ? targets.length : maxConcurrent,
        (_) => Future(() async {
          while (queue.isNotEmpty) {
            await runOne(queue.removeAt(0));
          }
        }),
      );
      await Future.wait(workers);
      if (!updates.isClosed) await updates.close();
    }());

    yield snapshot();
    yield* updates.stream;
    yield snapshot(loading: false);
  }
}
