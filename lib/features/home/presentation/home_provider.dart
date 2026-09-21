import 'dart:async';
import 'dart:io';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../core/extensions/extension_manager.dart';
import '../../../../core/storage/storage_service.dart';
import '../../../../core/extensions/base_provider.dart';

import './home_state.dart';

part 'home_provider.g.dart';

@riverpod
class HomeData extends _$HomeData {
  /// Retires superseded fetches. The notifier instance outlives a rebuild, so
  /// bumping this in [build] also cancels a fetch that is still in flight for
  /// the provider the user just switched away from — otherwise its late result
  /// lands on top of the grid the user is already looking at.
  int _fetchToken = 0;

  @override
  HomeState build() {
    _fetchToken++;
    final activeProvider = ref.watch(activeProviderProvider);
    if (activeProvider == null) {
      return const HomeNoProvider();
    }

    // Start initial fetch
    Future.microtask(() => fetch());
    return const HomeLoading();
  }

  Future<void> fetch() async {
    final token = ++_fetchToken;
    state = const HomeLoading();

    final activeProvider = ref.read(activeProviderProvider);
    if (activeProvider == null) {
      state = const HomeNoProvider();
      return;
    }

    // No reachability probe runs ahead of this: the request is the only honest
    // signal, it reports its own failure a moment later, and a hardcoded public
    // resolver is simply unreachable on networks that block one.
    try {
      final items = await activeProvider.getHome();
      if (!_isCurrent(token)) return;
      state = HomeSuccess(items);
    } catch (e) {
      if (!_isCurrent(token)) return;
      // A dead network must still reach the localized offline page rather than
      // a raw exception string, which is all the probe used to buy us.
      state = _looksOffline(e) ? const HomeOffline() : HomeError(e.toString());
    }
  }

  /// False once this fetch has been superseded, or once the provider has been
  /// disposed — a post-dispose `state =` throws `UnmountedRefException` on
  /// Riverpod 3.
  bool _isCurrent(int token) => token == _fetchToken && ref.mounted;

  /// The scraper wraps its failures in a plain `Exception`, so the type is
  /// often gone by the time it reaches here; match on the text too.
  static bool _looksOffline(Object error) {
    if (error is SocketException ||
        error is HandshakeException ||
        error is TimeoutException) {
      return true;
    }
    final text = error.toString();
    return text.contains('SocketException') ||
        text.contains('HandshakeException') ||
        text.contains('TimeoutException') ||
        text.contains('Failed host lookup') ||
        text.contains('Network is unreachable') ||
        text.contains('Connection refused') ||
        text.contains('Connection reset') ||
        text.contains('Connection timed out') ||
        text.contains('connectionError');
  }
}

@riverpod
class HomeFilter extends _$HomeFilter {
  @override
  ProviderType? build() {
    final storage = ref.read(storageServiceProvider);
    final saved = storage.getHomeCategory();
    if (saved != null) {
      try {
        return ProviderType.values.firstWhere((e) => e.name == saved);
      } catch (_) {}
    }
    return null;
  }

  Future<void> setFilter(ProviderType? type) async {
    state = type;
    final storage = ref.read(storageServiceProvider);
    await storage.setHomeCategory(type?.name);
  }
}
