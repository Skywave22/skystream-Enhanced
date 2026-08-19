import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/nuvio_models.dart';
import 'nuvio_repository.dart';
import 'nuvio_runtime.dart';

part 'nuvio_stream_service.g.dart';

@Riverpod(keepAlive: true)
NuvioStreamService nuvioStreamService(Ref ref) => NuvioStreamService(ref);

enum NuvioScraperOutcome { pending, links, empty, failed, unsupported }

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

/// Runs every enabled Nuvio scraper for one title and streams results back as
/// they arrive, mirroring how the SkyStream plugin aggregator behaves so both
/// systems can feed one list.
class NuvioStreamService {
  NuvioStreamService(this._ref);

  final Ref _ref;

  /// Scrapers are heavy (each spins its own QuickJS context), so the pool is
  /// deliberately small.
  static const int _maxConcurrent = 3;

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

    if (tmdbId.isEmpty || targets.isEmpty) {
      yield const NuvioProgress(isLoading: false);
      return;
    }

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

    Future<void> runOne(({NuvioRepo repo, NuvioScraperInfo scraper}) entry) async {
      final scraper = entry.scraper;
      try {
        final code = await repository.codeFor(entry.repo, scraper);
        final results = await runtime.run(
          code: code,
          scraperId: scraper.id,
          scraperName: scraper.name,
          tmdbId: tmdbId,
          mediaType: type,
          season: season,
          episode: episode,
        );

        var added = 0;
        for (final result in results) {
          if (!seen.add('${scraper.id}|${result.url}')) continue;
          streams.add(result);
          added++;
        }
        statuses[scraper.id] = NuvioScraperStatus(
          scraperName: scraper.name,
          outcome: added > 0
              ? NuvioScraperOutcome.links
              : NuvioScraperOutcome.empty,
          linkCount: added,
          message: added > 0 ? null : 'no links',
        );
      } on NuvioRuntimeException catch (error) {
        statuses[scraper.id] = NuvioScraperStatus(
          scraperName: scraper.name,
          outcome: NuvioScraperOutcome.unsupported,
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
        targets.length < _maxConcurrent ? targets.length : _maxConcurrent,
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
