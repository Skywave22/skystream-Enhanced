import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/addon_stream.dart';
import '../models/stremio_addon.dart';
import 'addon_client.dart';

part 'addon_stream_aggregator.g.dart';

@Riverpod(keepAlive: true)
AddonStreamAggregator addonStreamAggregator(Ref ref) =>
    AddonStreamAggregator(ref.watch(addonClientProvider));

/// Per-add-on outcome, surfaced in the sheet's diagnostics so "no links" is
/// always explainable instead of a silent empty list.
enum AddonQueryOutcome { pending, links, empty, failed }

class AddonQueryStatus {
  final String addonName;
  final AddonQueryOutcome outcome;
  final int linkCount;
  final String? message;

  const AddonQueryStatus({
    required this.addonName,
    required this.outcome,
    this.linkCount = 0,
    this.message,
  });
}

/// Progressive snapshot emitted while add-ons are still answering.
class AddonAggregateState {
  final List<AddonStream> streams;
  final List<AddonQueryStatus> statuses;
  final int completedCount;
  final int totalCount;
  final bool isLoading;
  final String? error;

  const AddonAggregateState({
    this.streams = const [],
    this.statuses = const [],
    this.completedCount = 0,
    this.totalCount = 0,
    this.isLoading = false,
    this.error,
  });

  double get progress =>
      totalCount == 0 ? 0 : (completedCount / totalCount).clamp(0.0, 1.0);

  List<String> get respondedAddons => [
    for (final status in statuses)
      if (status.outcome == AddonQueryOutcome.links) status.addonName,
  ];
}

/// Queries add-ons for `/stream` links, in parallel, streaming results as they
/// land. Nothing in here touches plugins — add-ons are a completely separate
/// pipeline with their own player.
class AddonStreamAggregator {
  AddonStreamAggregator(this._client);

  final AddonClient _client;

  static const int _maxConcurrent = 6;
  static const Duration _perAddonTimeout = Duration(seconds: 20);

  /// Add-ons that should be asked for `type`/`id`.
  ///
  /// Manifests are frequently sloppy — `idPrefixes` missing, `types` listing
  /// only `movie` while the add-on happily answers `series`, resources given
  /// as bare strings. So the strict manifest match is only a *preference*: if
  /// it yields nothing, every add-on that declares a `stream` resource is
  /// asked anyway. Better one wasted request than an empty sheet.
  static List<InstalledAddon> targetsFor(
    List<InstalledAddon> addons,
    String type,
    String id,
  ) {
    final strict = addons
        .where((a) => a.manifest.supports('stream', type, id))
        .toList();
    if (strict.isNotEmpty) return strict;

    final byType = addons
        .where(
          (a) =>
              a.manifest.hasResource('stream') &&
              (a.manifest.types.isEmpty || a.manifest.types.contains(type)),
        )
        .toList();
    if (byType.isNotEmpty) return byType;

    return addons.where((a) => a.manifest.hasResource('stream')).toList();
  }

  static int _compare(AddonStream a, AddonStream b) {
    // Instantly playable debrid links beat raw torrents of equal quality.
    if (a.isCachedDebrid != b.isCachedDebrid) return a.isCachedDebrid ? -1 : 1;
    final byQuality = b.qualityScore.compareTo(a.qualityScore);
    if (byQuality != 0) return byQuality;
    if (a.isCam != b.isCam) return a.isCam ? 1 : -1;
    if (a.isHdr != b.isHdr) return a.isHdr ? -1 : 1;
    final seedA = a.seeders ?? -1;
    final seedB = b.seeders ?? -1;
    if (seedA != seedB) return seedB.compareTo(seedA);
    final sizeA = a.sizeBytes ?? 0;
    final sizeB = b.sizeBytes ?? 0;
    if (sizeA != sizeB) return sizeB.compareTo(sizeA);
    return a.addonName.compareTo(b.addonName);
  }

  /// Tries each candidate id in order (e.g. the meta's own video id, then the
  /// constructed `tt…:S:E`, then an IMDb fallback) and stops at the first one
  /// that produces links.
  Stream<AddonAggregateState> aggregate({
    required List<InstalledAddon> addons,
    required String type,
    required List<String> ids,
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async* {
    final candidates = <String>[];
    for (final id in ids) {
      final trimmed = id.trim();
      if (trimmed.isNotEmpty && !candidates.contains(trimmed)) {
        candidates.add(trimmed);
      }
    }

    if (addons.isEmpty) {
      yield const AddonAggregateState(
        error:
            'No add-ons are enabled. Install a stream add-on (for example '
            'Torrentio) from the Add-ons tab.',
      );
      return;
    }
    if (candidates.isEmpty) {
      yield const AddonAggregateState(
        error: 'This title has no id that add-ons can be queried with.',
      );
      return;
    }

    AddonAggregateState? last;
    for (final id in candidates) {
      final targets = targetsFor(addons, type, id);
      if (targets.isEmpty) {
        last = const AddonAggregateState(
          isLoading: false,
          error:
              'None of your add-ons provide streams. Install one that lists '
              'the "stream" resource, such as Torrentio.',
        );
        continue;
      }

      await for (final state in _runOnce(
        targets: targets,
        type: type,
        id: id,
        forceRefresh: forceRefresh,
        cancelToken: cancelToken,
      )) {
        last = state;
        yield state;
      }

      if ((last?.streams.isNotEmpty ?? false)) return;
    }

    if (last != null && last.streams.isEmpty) {
      yield AddonAggregateState(
        statuses: last.statuses,
        completedCount: last.completedCount,
        totalCount: last.totalCount,
        error:
            last.error ??
            'No add-on returned links for ${candidates.first}. Check that a '
                'stream add-on is installed, enabled and reachable.',
      );
    }
  }

  Stream<AddonAggregateState> _runOnce({
    required List<InstalledAddon> targets,
    required String type,
    required String id,
    required bool forceRefresh,
    CancelToken? cancelToken,
  }) async* {
    final streams = <AddonStream>[];
    final seen = <String>{};
    final statuses = <String, AddonQueryStatus>{
      for (final addon in targets)
        addon.id: AddonQueryStatus(
          addonName: addon.name,
          outcome: AddonQueryOutcome.pending,
        ),
    };
    var completed = 0;

    final updates = StreamController<AddonAggregateState>();

    AddonAggregateState snapshot({bool loading = true}) {
      streams.sort(_compare);
      return AddonAggregateState(
        streams: List.of(streams),
        statuses: statuses.values.toList(),
        completedCount: completed,
        totalCount: targets.length,
        isLoading: loading,
      );
    }

    Future<void> runOne(InstalledAddon addon) async {
      try {
        final results = await _client
            .streams(
              addon,
              type: type,
              id: id,
              forceRefresh: forceRefresh,
              cancelToken: cancelToken,
            )
            .timeout(_perAddonTimeout);

        var added = 0;
        for (final stream in results) {
          if (!seen.add(stream.uniqueKey)) continue;
          streams.add(stream);
          added++;
        }
        statuses[addon.id] = AddonQueryStatus(
          addonName: addon.name,
          outcome: results.isEmpty
              ? AddonQueryOutcome.empty
              : AddonQueryOutcome.links,
          linkCount: added,
        );
        if (!updates.isClosed) updates.add(snapshot());
      } catch (error) {
        statuses[addon.id] = AddonQueryStatus(
          addonName: addon.name,
          outcome: AddonQueryOutcome.failed,
          message: error is DioException
              ? (error.message ?? error.type.name)
              : error.toString(),
        );
        if (kDebugMode) {
          debugPrint('[AddonStreamAggregator] ${addon.name} ($id): $error');
        }
      } finally {
        completed++;
        if (!updates.isClosed) updates.add(snapshot());
      }
    }

    unawaited(() async {
      final queue = List<InstalledAddon>.of(targets);
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

    streams.sort(_compare);
    yield AddonAggregateState(
      streams: streams,
      statuses: statuses.values.toList(),
      completedCount: completed,
      totalCount: targets.length,
    );
  }

  /// One-shot variant used for pre-fetching.
  Future<List<AddonStream>> fetchAll({
    required List<InstalledAddon> addons,
    required String type,
    required String id,
  }) async {
    final targets = targetsFor(addons, type, id);
    if (targets.isEmpty) return const [];

    Future<List<AddonStream>> safeFetch(InstalledAddon addon) async {
      try {
        return await _client
            .streams(addon, type: type, id: id)
            .timeout(_perAddonTimeout);
      } catch (_) {
        return const <AddonStream>[];
      }
    }

    final results = await Future.wait(targets.map(safeFetch));

    final seen = <String>{};
    final out = <AddonStream>[];
    for (final list in results) {
      for (final stream in list) {
        if (seen.add(stream.uniqueKey)) out.add(stream);
      }
    }
    out.sort(_compare);
    return out;
  }
}
