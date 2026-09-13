import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/tracking/data/sync_manager.dart';
import 'package:skystream/features/tracking/data/sync_outbox.dart';
import 'package:skystream/features/tracking/data/tracking_service.dart';
import 'package:skystream/features/tracking/domain/sync_progress_item.dart';

/// Durability for the terminal tracking writes.
///
/// Before the outbox, `markWatched` and `scrobbleStop` were one `unawaited`
/// HTTP call each. A user finishing an episode on a train — which is exactly
/// when a phone hands over between networks — lost the mark permanently, while
/// the app's own episode list still showed it watched. These tests pin the four
/// properties that stop that: the write is on disk before it is attempted, it
/// is replayed after a restart, a replay never re-sends to a service that
/// already took it, and the queue cannot grow without bound.

/// Records what it was asked to do and can be told to fail.
class _FakeService implements TrackingService {
  _FakeService(this.idPrefix);

  @override
  final String idPrefix;

  bool loggedIn = true;
  bool failWrites = false;
  final List<String> calls = <String>[];

  @override
  String get name => idPrefix;

  @override
  String get mainUrl => 'https://$idPrefix.test';

  @override
  Future<bool> get isLoggedIn async => loggedIn;

  @override
  Future<bool> login({
    Future<void> Function(String url, String code)? onDeviceCodeGenerated,
    Future<void> Function(String url)? onWebViewRequested,
    bool Function()? isCancelled,
  }) async => false;

  @override
  Future<void> logout() async {}

  @override
  Future<List<MultimediaItem>> search(String query) async => [];

  @override
  Future<Map<String, String>> syncIds(MultimediaItem item) async => {};

  bool _record(String call) {
    calls.add(call);
    return !failWrites;
  }

  @override
  Future<bool> markWatched(
    MultimediaItem item,
    Episode? episode, {
    Map<String, String>? resolvedIds,
  }) async => _record('markWatched');

  @override
  Future<bool> scrobbleStart(
    MultimediaItem item,
    Episode? episode,
    double progress, {
    Map<String, String>? resolvedIds,
  }) async => _record('scrobbleStart');

  @override
  Future<bool> scrobblePause(
    MultimediaItem item,
    Episode? episode,
    double progress, {
    Map<String, String>? resolvedIds,
  }) async => _record('scrobblePause');

  @override
  Future<bool> scrobbleStop(
    MultimediaItem item,
    Episode? episode,
    double progress, {
    Map<String, String>? resolvedIds,
  }) async => _record('scrobbleStop@$progress');

  @override
  Future<bool> addToPlanToWatch(
    MultimediaItem item, {
    Map<String, String>? resolvedIds,
  }) async => _record('addToPlanToWatch');

  @override
  Future<List<SyncProgressItem>> pullPlaybackProgress() async => [];

  @override
  Future<bool> removePlaybackProgress(String id) async => false;
}

/// Stands in for the Hive settings box: one string, and it survives the
/// "restart" because the test holds it, not the outbox.
class _MemoryStore implements SyncOutboxStore {
  String? value;

  @override
  String? read() => value;

  @override
  Future<void> write(String? v) async {
    value = v;
  }

  List<Map<String, dynamic>> get rows => value == null
      ? const []
      : (jsonDecode(value!) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
}

void main() {
  final item = MultimediaItem(
    title: 'Show',
    url: 'https://example.com/show',
    posterUrl: '',
    contentType: MultimediaContentType.series,
    tmdbId: 1399,
    imdbId: 'tt0944947',
  );
  final s1e1 = Episode(name: 'E1', url: 'e1', season: 1, episode: 1);
  final s1e2 = Episode(name: 'E2', url: 'e2', season: 1, episode: 2);

  late int nowMs;
  DateTime clock() => DateTime.fromMillisecondsSinceEpoch(nowMs);

  setUp(() => nowMs = DateTime.utc(2026, 9, 12, 12).millisecondsSinceEpoch);

  SyncOutbox outbox(
    _MemoryStore store, {
    int maxEntries = 100,
    int maxAttempts = 20,
    int maxAgeMs = 7 * 24 * 60 * 60 * 1000,
    int maxStopAgeMs = 60 * 60 * 1000,
  }) => SyncOutbox(
    store: store,
    clock: clock,
    maxEntries: maxEntries,
    maxAttempts: maxAttempts,
    maxAgeMs: maxAgeMs,
    maxStopAgeMs: maxStopAgeMs,
    // The tests step the injected clock and call drain() themselves; a real
    // Timer would still be pending at teardown.
    autoRetry: false,
  );

  group('a write survives the flap that lost it', () {
    test(
      'is persisted before it is attempted, and replayed on restart',
      () async {
        final store = _MemoryStore();
        final offline = _FakeService('trakt')..failWrites = true;
        final box = outbox(store);
        final manager = SyncManager([offline], outbox: box);
        await box.started;

        await manager.markWatched(item, s1e1, sessionKey: '7');
        await box.drain();

        // It was tried, it failed, and — the part that used to be missing — it
        // is on disk rather than gone.
        expect(offline.calls, ['markWatched']);
        expect(store.rows, hasLength(1));
        expect(store.rows.single['op'], 'markWatched');
        expect(store.rows.single['item']['url'], item.url);
        expect(store.rows.single['episode']['number'], 1);

        // Restart, a few minutes later: a brand-new manager and outbox over
        // the same bytes, network back up. Nothing in memory carries over.
        nowMs += const Duration(minutes: 5).inMilliseconds;
        final online = _FakeService('trakt');
        final revived = outbox(store);
        SyncManager([online], outbox: revived);
        await revived.started;

        expect(online.calls, ['markWatched']);
        expect(store.value, isNull, reason: 'delivered entries are removed');
      },
    );

    test('a scrobble stop keeps the progress it was queued with', () async {
      final store = _MemoryStore();
      final offline = _FakeService('trakt')..failWrites = true;
      final box = outbox(store);
      final manager = SyncManager([offline], outbox: box);
      await box.started;

      await manager.scrobbleStop(item, s1e1, 0.42, sessionKey: '7');
      await box.drain();

      nowMs += const Duration(minutes: 5).inMilliseconds;
      final online = _FakeService('trakt');
      final revived = outbox(store);
      SyncManager([online], outbox: revived);
      await revived.started;

      expect(online.calls, ['scrobbleStop@0.42']);
    });
  });

  group('a retry cannot double-count', () {
    test('a service that already took the write is never re-sent', () async {
      final store = _MemoryStore();
      // Trakt's scrobble/stop is not idempotent: a second one is a second play.
      final trakt = _FakeService('trakt')..failWrites = true;
      final simkl = _FakeService('simkl');
      final box = outbox(store);
      final manager = SyncManager([simkl, trakt], outbox: box);
      await box.started;

      await manager.markWatched(item, s1e1, sessionKey: '7');
      await box.drain();

      expect(simkl.calls, ['markWatched']);
      expect(trakt.calls, ['markWatched']);
      expect(store.rows.single['delivered'], ['simkl']);

      trakt.failWrites = false;
      nowMs += const Duration(minutes: 5).inMilliseconds;
      await box.drain();

      expect(simkl.calls, [
        'markWatched',
      ], reason: 'simkl already confirmed it; a replay would count it twice');
      expect(trakt.calls, ['markWatched', 'markWatched']);
      expect(store.value, isNull);
    });

    test('the same session emitting twice queues one entry', () async {
      final store = _MemoryStore();
      final offline = _FakeService('trakt')..failWrites = true;
      final box = outbox(store);
      final manager = SyncManager([offline], outbox: box);
      await box.started;

      await manager.markWatched(item, s1e1, sessionKey: '7');
      await box.drain();
      await manager.markWatched(item, s1e1, sessionKey: '7');
      await box.drain();

      expect(box.length, 1);
      expect(store.rows, hasLength(1));
    });

    // Both `Episode.season` and `Episode.episode` default to 0, and plenty of
    // providers return an episode list with no numbering at all. With the
    // numbers alone in the key, every episode of such a series is one identity
    // for any caller that does not supply a per-viewing session — `sessionKey`
    // is optional on the whole SyncManager API — so the second and third marks
    // are dropped as duplicates of the first and never reach Trakt.
    //
    // Today's two live emitters (PlaybackTracker's markWatched and
    // scrobbleStop) both pass a session key that is now unique per viewing, so
    // this is the contract of the identity function rather than a reachable
    // path; it is what stops the next caller of the optional-session API from
    // silently losing episodes.
    test('an unnumbered episode is addressed by url, not just by number', () {
      final unnumbered1 = Episode(name: 'One', url: 'https://ep/1');
      final unnumbered2 = Episode(name: 'Two', url: 'https://ep/2');
      expect(unnumbered1.season, 0);
      expect(unnumbered1.episode, 0);

      expect(
        syncOutboxKey(SyncOp.markWatched, item, unnumbered1, null),
        isNot(syncOutboxKey(SyncOp.markWatched, item, unnumbered2, null)),
      );
    });

    test('an unnumbered episode list does not collapse onto one key', () async {
      final store = _MemoryStore();
      final offline = _FakeService('trakt')..failWrites = true;
      final box = outbox(store);
      final manager = SyncManager([offline], outbox: box);
      await box.started;

      // No sessionKey: the API default, and what any caller that is not one
      // player session — a bulk "mark season watched" — would pass.
      await manager.markWatched(
        item,
        Episode(name: 'One', url: 'https://ep/1'),
      );
      await manager.markWatched(
        item,
        Episode(name: 'Two', url: 'https://ep/2'),
      );
      await box.drain();

      expect(box.length, 2);
      expect(box.entries.map((e) => e.episode!.url), <String>[
        'https://ep/1',
        'https://ep/2',
      ]);
    });

    test('a genuinely new viewing queues its own entry', () async {
      final store = _MemoryStore();
      final offline = _FakeService('trakt')..failWrites = true;
      final box = outbox(store);
      final manager = SyncManager([offline], outbox: box);
      await box.started;

      await manager.markWatched(item, s1e1, sessionKey: '7');
      await manager.markWatched(item, s1e1, sessionKey: '8');
      await manager.markWatched(item, s1e2, sessionKey: '8');
      await box.drain();

      expect(box.length, 3);
    });
  });

  group('backoff', () {
    test('a failed entry is not retried until its delay has elapsed', () async {
      final store = _MemoryStore();
      final offline = _FakeService('trakt')..failWrites = true;
      final box = SyncOutbox(
        store: store,
        clock: clock,
        autoRetry: false,
        baseBackoff: const Duration(seconds: 30),
      );
      final manager = SyncManager([offline], outbox: box);
      await box.started;

      await manager.markWatched(item, s1e1, sessionKey: '7');
      await box.drain();
      expect(offline.calls, hasLength(1));

      nowMs += const Duration(seconds: 29).inMilliseconds;
      await box.drain();
      expect(offline.calls, hasLength(1), reason: 'still inside the backoff');

      nowMs += const Duration(seconds: 2).inMilliseconds;
      await box.drain();
      expect(offline.calls, hasLength(2));

      // ...and the next wait is longer than the last.
      nowMs += const Duration(seconds: 31).inMilliseconds;
      await box.drain();
      expect(offline.calls, hasLength(2), reason: 'the delay doubled to 60s');
    });
  });

  group('the queue is bounded', () {
    test('a long offline stretch drops the oldest entries', () async {
      final store = _MemoryStore();
      final offline = _FakeService('trakt')..failWrites = true;
      final box = outbox(store, maxEntries: 2);
      final manager = SyncManager([offline], outbox: box);
      await box.started;

      for (var i = 1; i <= 4; i++) {
        await manager.markWatched(
          item,
          Episode(name: 'E$i', url: 'e$i', season: 1, episode: i),
          sessionKey: '7',
        );
      }
      await box.drain();

      expect(box.length, 2);
      expect(box.entries.map((e) => e.episode!.episode), [
        3,
        4,
      ], reason: 'tonight is worth more than a fortnight ago');
    });

    test('an entry older than the age cap is dropped, not sent', () async {
      final store = _MemoryStore();
      final ancient = SyncOutboxEntry(
        key: 'markWatched|${item.url}|1x1|old',
        op: SyncOp.markWatched,
        item: item,
        episode: s1e1,
        progress: 1.0,
        enqueuedAtMs: nowMs - const Duration(days: 30).inMilliseconds,
      );
      store.value = jsonEncode([ancient.toJson()]);

      final service = _FakeService('trakt');
      final box = outbox(store);
      SyncManager([service], outbox: box);
      await box.started;

      expect(service.calls, isEmpty);
      expect(box.length, 0);
    });

    // A stop carries *where the user was*, and the scrobble wire format has no
    // field for when: Trakt stamps paused_at with its own receipt time. So a
    // stop replayed hours later arrives looking like the newest thing on the
    // account and overwrites the point a newer viewing — very often on another
    // device — already recorded. Phone queues stop(0.25) offline at 20:00, the
    // television watches the same title to 70% at 21:00, the phone reconnects
    // at 23:00: without this cap every device resolves back to 25%. A mark is
    // not like that — "seen" is as true a week later — so it keeps the long
    // window.
    test(
      'a stop past its freshness window is dropped, a mark is not',
      () async {
        final store = _MemoryStore();
        final threeHoursAgo = nowMs - const Duration(hours: 3).inMilliseconds;
        store.value = jsonEncode([
          SyncOutboxEntry(
            key: 'markWatched|${item.url}|1x1|e1|old',
            op: SyncOp.markWatched,
            item: item,
            episode: s1e1,
            progress: 1.0,
            enqueuedAtMs: threeHoursAgo,
          ).toJson(),
          SyncOutboxEntry(
            key: 'scrobbleStop|${item.url}|1x2|e2|old',
            op: SyncOp.scrobbleStop,
            item: item,
            episode: s1e2,
            progress: 0.25,
            enqueuedAtMs: threeHoursAgo,
          ).toJson(),
        ]);

        final service = _FakeService('trakt');
        final box = outbox(store);
        SyncManager([service], outbox: box);
        await box.started;

        expect(
          service.calls,
          <String>['markWatched'],
          reason:
              'the three-hour-old stop would have overwritten a newer point',
        );
        expect(box.length, 0);
      },
    );

    test('a stop inside its freshness window is still replayed', () async {
      final store = _MemoryStore();
      final offline = _FakeService('trakt')..failWrites = true;
      final box = outbox(store);
      final manager = SyncManager([offline], outbox: box);
      await box.started;

      await manager.scrobbleStop(item, s1e1, 0.42, sessionKey: 'a');
      await box.drain();
      expect(box.length, 1);

      // The flap the outbox exists for: half an hour in a tunnel, then back.
      nowMs += const Duration(minutes: 30).inMilliseconds;
      final online = _FakeService('trakt');
      final revived = outbox(store);
      SyncManager([online], outbox: revived);
      await revived.started;

      expect(online.calls, <String>['scrobbleStop@0.42']);
      expect(revived.length, 0);
    });

    test('an entry nothing will ever accept is given up on', () async {
      final store = _MemoryStore();
      final broken = _FakeService('trakt')..failWrites = true;
      final box = outbox(store, maxAttempts: 3);
      final manager = SyncManager([broken], outbox: box);
      await box.started;

      await manager.markWatched(item, s1e1, sessionKey: '7');
      for (var i = 0; i < 5; i++) {
        nowMs += const Duration(hours: 4).inMilliseconds;
        await box.drain();
      }

      expect(broken.calls, hasLength(3));
      expect(box.length, 0);
      expect(store.value, isNull);
    });
  });

  group('what does not get queued', () {
    test('scrobble start and pause stay fire-and-forget', () async {
      final store = _MemoryStore();
      final offline = _FakeService('trakt')..failWrites = true;
      final box = outbox(store);
      final manager = SyncManager([offline], outbox: box);
      await box.started;

      await manager.scrobbleStart(item, s1e1, 0.05);
      await manager.scrobblePause(item, s1e1, 0.12);
      await box.drain();

      expect(offline.calls, ['scrobbleStart', 'scrobblePause']);
      expect(
        box.length,
        0,
        reason: 'a stale "watching now" is a lie, not data',
      );
      expect(store.value, isNull);
    });

    test('a livestream is not queued', () async {
      final store = _MemoryStore();
      final offline = _FakeService('trakt')..failWrites = true;
      final box = outbox(store);
      final manager = SyncManager([offline], outbox: box);
      await box.started;

      await manager.markWatched(
        MultimediaItem(
          title: 'Channel',
          url: 'https://example.com/live',
          posterUrl: '',
          contentType: MultimediaContentType.livestream,
          tmdbId: 1,
        ),
        null,
        sessionKey: '7',
      );
      await box.drain();

      expect(offline.calls, isEmpty);
      expect(box.length, 0);
    });

    test(
      'an id-bound service with no resolved id is not owed the write',
      () async {
        final store = _MemoryStore();
        // AniList can only be addressed by an AniList id and this title has
        // none, so it must not hold the entry open forever.
        final anilist = _FakeService('anilist')..failWrites = true;
        final trakt = _FakeService('trakt');
        final box = outbox(store);
        final manager = SyncManager([anilist, trakt], outbox: box);
        await box.started;

        await manager.markWatched(item, s1e1, sessionKey: '7');
        await box.drain();

        expect(anilist.calls, isEmpty);
        expect(trakt.calls, ['markWatched']);
        expect(box.length, 0);
      },
    );
  });

  group('without a store', () {
    test('a manager with no outbox still writes, exactly as before', () async {
      final trakt = _FakeService('trakt');
      final manager = SyncManager([trakt]);

      await manager.markWatched(item, s1e1, sessionKey: '7');
      await manager.scrobbleStop(item, s1e1, 0.9, sessionKey: '7');

      expect(trakt.calls, ['markWatched', 'scrobbleStop@0.9']);
    });
  });
}
