/// `HomeData`: late-result discipline and the removal of the public-DNS
/// reachability probe.
///
/// Two hazards are pinned here.
///
/// 1. A fetch that has been superseded — by a second `fetch()` (pull to
///    refresh), by the user switching active provider, or by the provider
///    being disposed — must never write its result. Before the fix, provider
///    A hanging while the user switched to B meant A's late result replaced
///    the grid B had already drawn, and a post-dispose write throws
///    `UnmountedRefException` on Riverpod 3.
///
/// 2. `fetch()` used to `await InternetAddress.lookup('dns.google')` before
///    doing anything. The tests below advance only the microtask queue, never
///    the event loop, so no real IO can complete inside them: any code that
///    waits on a socket cannot reach the scraper here at all.
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/extensions/base_provider.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/features/home/presentation/home_provider.dart';
import 'package:skystream/features/home/presentation/home_state.dart';

typedef _Sections = Map<String, List<MultimediaItem>>;

/// A scraper stand-in. Every `getHome()` returns a fresh completer so a test
/// can decide exactly when — and in which order — each call lands.
class _FakeScraper extends SkyStreamProvider {
  _FakeScraper(this.name);

  @override
  final String name;

  final List<Completer<_Sections>> calls = [];

  int get callCount => calls.length;

  @override
  Future<_Sections> getHome() {
    final completer = Completer<_Sections>();
    calls.add(completer);
    return completer.future;
  }

  /// Completes the [index]-th (0-based) outstanding call with one section.
  void resolve(int index, String section) =>
      calls[index].complete({section: <MultimediaItem>[]});

  void fail(int index, Object error) => calls[index].completeError(error);

  @override
  String get packageName => 'fake.$name';
  @override
  String get mainUrl => 'https://$name.test';
  @override
  String get version => '1.0.0';
  @override
  List<String> get languages => const ['en'];
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.movie};
  @override
  Future<List<MultimediaItem>> search(String query, {CancelToken? cancelToken}) =>
      throw UnimplementedError();
  @override
  Future<MultimediaItem> getDetails(String url) => throw UnimplementedError();
  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      throw UnimplementedError();
}

/// The real notifier reaches for storage and the extension manager on every
/// write; this keeps the state transition and drops the persistence.
class _FakeActiveProvider extends ActiveProvider {
  _FakeActiveProvider(this._initial);

  final SkyStreamProvider? _initial;

  @override
  SkyStreamProvider? build() => _initial;

  @override
  Future<void> set(SkyStreamProvider? provider) async {
    state = provider;
  }
}

/// Drains the microtask queue without ever yielding to the event loop, so a
/// real socket or DNS callback cannot slip in. Anything gated on IO stays
/// exactly where it is.
Future<void> _settle([int turns = 64]) async {
  for (var i = 0; i < turns; i++) {
    await Future.microtask(() {});
  }
}

ProviderContainer _containerWith(SkyStreamProvider? active) {
  final container = ProviderContainer(
    overrides: [
      activeProviderProvider.overrideWith(() => _FakeActiveProvider(active)),
    ],
  );
  addTearDown(container.dispose);
  // homeDataProvider is autoDispose; keep it alive for the whole test.
  container.listen(homeDataProvider, (_, _) {});
  return container;
}

Set<String> _sectionsOf(HomeState state) =>
    (state as HomeSuccess).data.keys.toSet();

void main() {
  group('HomeData does not gate the home load on a public DNS probe', () {
    test('reaches the scraper without waiting on any socket', () async {
      final scraper = _FakeScraper('a');
      final container = _containerWith(scraper);

      await _settle();

      // No event-loop turn has happened, so a reachability probe could not
      // have resolved. The scraper must already have been asked.
      expect(
        scraper.callCount,
        1,
        reason: 'the home fetch must not wait on an external resolver',
      );

      scraper.resolve(0, 'Trending');
      await _settle();

      expect(_sectionsOf(container.read(homeDataProvider)), {'Trending'});
    });

    test('a raw SocketException lands on the offline state', () async {
      final scraper = _FakeScraper('a');
      final container = _containerWith(scraper);
      await _settle();

      expect(scraper.callCount, 1);
      scraper.fail(
        0,
        const SocketException('Failed host lookup: a.test'),
      );
      await _settle();

      expect(container.read(homeDataProvider), isA<HomeOffline>());
    });

    test(
      'a scraper-wrapped SocketException still lands on the offline state',
      () async {
        final scraper = _FakeScraper('a');
        final container = _containerWith(scraper);
        await _settle();

        expect(scraper.callCount, 1);
        // Exactly what JsBasedProvider.getHome rethrows: the type is gone and
        // only the text survives.
        scraper.fail(
          0,
          Exception(
            'Failed to load home content: SocketException: Failed host '
            'lookup: a.test (OS Error: nodename nor servname provided)',
          ),
        );
        await _settle();

        expect(container.read(homeDataProvider), isA<HomeOffline>());
      },
    );

    test('a plugin failure keeps its own message instead of offline', () async {
      final scraper = _FakeScraper('a');
      final container = _containerWith(scraper);
      await _settle();

      expect(scraper.callCount, 1);
      scraper.fail(
        0,
        Exception('Extension returned invalid home data (not a map).'),
      );
      await _settle();

      final state = container.read(homeDataProvider);
      expect(state, isA<HomeError>());
      expect(
        (state as HomeError).message,
        contains('Extension returned invalid home data'),
      );
    });
  });

  group('HomeData discards superseded fetches', () {
    test('a slow first fetch cannot overwrite a newer refresh', () async {
      final scraper = _FakeScraper('a');
      final container = _containerWith(scraper);
      await _settle();
      expect(scraper.callCount, 1);

      // Pull to refresh while the first fetch is still in flight.
      unawaited(container.read(homeDataProvider.notifier).fetch());
      await _settle();
      expect(scraper.callCount, 2);

      scraper.resolve(1, 'Fresh');
      await _settle();
      expect(_sectionsOf(container.read(homeDataProvider)), {'Fresh'});

      // The abandoned first fetch finally answers.
      scraper.resolve(0, 'Stale');
      await _settle();

      expect(
        _sectionsOf(container.read(homeDataProvider)),
        {'Fresh'},
        reason: 'the abandoned first fetch must not win by arriving last',
      );
    });

    test(
      'a hung provider cannot overwrite the one the user switched to',
      () async {
        final slow = _FakeScraper('slow');
        final fast = _FakeScraper('fast');
        final container = _containerWith(slow);
        await _settle();
        expect(slow.callCount, 1, reason: 'slow provider fetch is in flight');

        // The user opens the provider selector and picks another provider.
        unawaited(container.read(activeProviderProvider.notifier).set(fast));
        // The home screen reads the rebuilt state on the next frame.
        expect(container.read(homeDataProvider), isA<HomeLoading>());
        await _settle();
        expect(fast.callCount, 1);

        fast.resolve(0, 'Fast');
        await _settle();
        expect(_sectionsOf(container.read(homeDataProvider)), {'Fast'});

        // Seconds later the abandoned provider finally answers.
        slow.resolve(0, 'Slow');
        await _settle();

        expect(
          _sectionsOf(container.read(homeDataProvider)),
          {'Fast'},
          reason: "a retired provider's late result must not replace the grid",
        );
      },
    );

    test('clearing the active provider is not undone by a late result', () async {
      final slow = _FakeScraper('slow');
      final container = _containerWith(slow);
      await _settle();
      expect(slow.callCount, 1);

      // Provider uninstalled / deselected: build() returns HomeNoProvider and
      // schedules no fetch of its own, so only the token bumped in build()
      // can retire the in-flight one.
      unawaited(container.read(activeProviderProvider.notifier).set(null));
      await _settle();
      expect(container.read(homeDataProvider), isA<HomeNoProvider>());

      slow.resolve(0, 'Slow');
      await _settle();

      expect(
        container.read(homeDataProvider),
        isA<HomeNoProvider>(),
        reason: 'a fetch from the removed provider must not resurrect a grid',
      );
    });

    test('a result arriving after dispose does not throw', () async {
      final scraper = _FakeScraper('a');
      final container = ProviderContainer(
        overrides: [
          activeProviderProvider.overrideWith(
            () => _FakeActiveProvider(scraper),
          ),
        ],
      );
      container.listen(homeDataProvider, (_, _) {});
      await _settle();
      expect(scraper.callCount, 1);

      // A fetch whose future we can observe, e.g. the header refresh button.
      final pending = container.read(homeDataProvider.notifier).fetch();
      await _settle();
      expect(scraper.callCount, 2);

      // The user leaves the home screen.
      container.dispose();

      scraper.resolve(1, 'Late');
      scraper.resolve(0, 'Later');

      // On Riverpod 3 a post-dispose `state =` throws UnmountedRefException.
      await expectLater(pending, completes);
    });
  });
}
