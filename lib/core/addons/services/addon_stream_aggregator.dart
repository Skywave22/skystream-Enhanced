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

/// Progressive snapshot emitted while add-ons are still answering.
class AddonAggregateState {
  final List<AddonStream> streams;
  final List<String> respondedAddons;
  final int completedCount;
  final int totalCount;
  final bool isLoading;
  final String? error;

  const AddonAggregateState({
    this.streams = const [],
    this.respondedAddons = const [],
    this.completedCount = 0,
    this.totalCount = 0,
    this.isLoading = false,
    this.error,
  });

  double get progress =>
      totalCount == 0 ? 0 : (completedCount / totalCount).clamp(0.0, 1.0);
}

/// Queries every enabled add-on that declares the `stream` resource, in
/// parallel, and streams results as they land.
///
/// Speed notes: requests go out concurrently (bounded), each add-on has its
/// own short timeout so one dead host can't stall the sheet, and the client
/// layer caches/coalesces so repeat opens are instant.
class AddonStreamAggregator {
  AddonStreamAggregator(this._client);

  final AddonClient _client;

  static const int _maxConcurrent = 6;
  static const Duration _perAddonTimeout = Duration(seconds: 18);

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

  Stream<AddonAggregateState> aggregate({
    required List<InstalledAddon> addons,
    required String type,
    required String id,
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async* {
    final targets = addons
        .where((a) => a.manifest.supports('stream', type, id))
        .toList();

    if (targets.isEmpty) {
      yield const AddonAggregateState(
        error: 'No installed add-on provides streams for this title.',
      );
      return;
    }

    final streams = <AddonStream>[];
    final responded = <String>[];
    final seen = <String>{};
    var completed = 0;

    final updates = StreamController<AddonAggregateState>();

    AddonAggregateState snapshot({bool loading = true}) {
      streams.sort(_compare);
      return AddonAggregateState(
        streams: List.of(streams),
        respondedAddons: List.of(responded),
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

        if (results.isNotEmpty) responded.add(addon.name);
        for (final stream in results) {
          if (!seen.add(stream.uniqueKey)) continue;
          streams.add(stream);
        }
        if (!updates.isClosed) updates.add(snapshot());
      } catch (error) {
        if (kDebugMode) {
          debugPrint('[AddonStreamAggregator] ${addon.name}: $error');
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
      respondedAddons: responded,
      completedCount: completed,
      totalCount: targets.length,
      isLoading: false,
      error: streams.isEmpty
          ? 'No links found for this title in your add-ons.'
          : null,
    );
  }

  /// One-shot variant used for pre-fetching (e.g. warming the next episode).
  Future<List<AddonStream>> fetchAll({
    required List<InstalledAddon> addons,
    required String type,
    required String id,
  }) async {
    final targets = addons
        .where((a) => a.manifest.supports('stream', type, id))
        .toList();
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
