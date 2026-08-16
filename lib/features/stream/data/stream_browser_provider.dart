import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/network/dio_client_provider.dart';
import '../../../core/services/tmdb_service.dart';
import 'stream_aggregator.dart';

final tmdbClientProvider = Provider<TmdbService>((ref) {
  return TmdbService(ref.watch(dioClientProvider));
});

final streamAggregatorProvider = Provider<StreamAggregator>((ref) {
  return StreamAggregator();
});

class StreamBrowserState {
  final AsyncValue<List<MultimediaItem>> movies;
  final AsyncValue<List<MultimediaItem>> series;
  final int tabIndex;

  const StreamBrowserState({
    this.movies = const AsyncLoading(),
    this.series = const AsyncLoading(),
    this.tabIndex = 0,
  });

  StreamBrowserState copyWith({
    AsyncValue<List<MultimediaItem>>? movies,
    AsyncValue<List<MultimediaItem>>? series,
    int? tabIndex,
  }) {
    return StreamBrowserState(
      movies: movies ?? this.movies,
      series: series ?? this.series,
      tabIndex: tabIndex ?? this.tabIndex,
    );
  }
}

class StreamBrowserNotifier extends Notifier<StreamBrowserState> {
  @override
  StreamBrowserState build() {
    // Kick off loading after build completes so we never mutate state
    // while the notifier is still initializing.
    Future.microtask(load);
    return const StreamBrowserState();
  }

  Future<void> load() async {
    final service = ref.read(tmdbClientProvider);
    unawaited(unawaitedLoadMovies(service));
    unawaited(unawaitedLoadSeries(service));
  }

  Future<void> unawaitedLoadMovies(TmdbService service) async {
    try {
      final items = await service.getTrendingMovies();
      state = state.copyWith(movies: AsyncData(items));
    } catch (error, stack) {
      state = state.copyWith(movies: AsyncError(error, stack));
    }
  }

  Future<void> unawaitedLoadSeries(TmdbService service) async {
    try {
      final items = await service.getPopularTV();
      state = state.copyWith(series: AsyncData(items));
    } catch (error, stack) {
      state = state.copyWith(series: AsyncError(error, stack));
    }
  }

  void setTab(int index) {
    if (index != state.tabIndex) state = state.copyWith(tabIndex: index);
  }
}

final streamBrowserProvider =
    NotifierProvider<StreamBrowserNotifier, StreamBrowserState>(
      StreamBrowserNotifier.new,
    );
