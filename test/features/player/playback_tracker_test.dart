import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart'
    show ProviderListenable;
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/player/domain/playback_progress.dart';
import 'package:skystream/features/player/domain/playback_tracker.dart';
import 'package:skystream/core/storage/episode_watch_repository.dart';
import 'package:skystream/core/storage/history_repository.dart';
import 'package:skystream/features/library/presentation/history_provider.dart';
import 'package:skystream/features/tracking/data/sync_manager.dart';

/// Records dispatches instead of writing to anyone's account.
class _RecordingSync extends SyncManager {
  _RecordingSync() : super(const []);

  final List<String> calls = <String>[];

  /// Session keys seen on the terminal writes. The outbox keys de-duplication
  /// on these, so a terminal write arriving without one would be replayable
  /// against the wrong viewing.
  final List<String?> terminalSessionKeys = <String?>[];

  @override
  Future<void> markWatched(
    MultimediaItem item,
    Episode? episode, {
    String? sessionKey,
  }) async {
    calls.add('markWatched');
    terminalSessionKeys.add(sessionKey);
  }

  @override
  Future<void> scrobbleStart(
    MultimediaItem item,
    Episode? episode,
    double progress,
  ) async {
    calls.add('scrobbleStart');
  }

  @override
  Future<void> scrobblePause(
    MultimediaItem item,
    Episode? episode,
    double progress,
  ) async {
    calls.add('scrobblePause');
  }

  @override
  Future<void> scrobbleStop(
    MultimediaItem item,
    Episode? episode,
    double progress, {
    String? sessionKey,
  }) async {
    calls.add('scrobbleStop');
    terminalSessionKeys.add(sessionKey);
  }
}

void main() {
  late _RecordingSync sync;

  // A series with no episode list touches only the sync provider on
  // completion — the roll-forward cannot locate a current episode, so it makes
  // no claim about the series either way. That keeps these tests free of
  // storage fakes; the roll-forward itself is covered below with a real list.
  final item = MultimediaItem(
    title: 'Show',
    url: 'https://example.com/show',
    posterUrl: '',
    contentType: MultimediaContentType.series,
  );

  T read<T>(ProviderListenable<T> provider) {
    if (identical(provider, syncManagerProvider)) return sync as T;
    throw StateError('tracker read an unexpected provider: $provider');
  }

  PlaybackTracker tracker() => PlaybackTracker(
    read: read,
    item: item,
    episode: null,
    videoUrl: 'https://example.com/show/1',
    token: 3,
  );

  ProgressSample at(int posMs, {int durMs = 3600000, int token = 3}) =>
      ProgressSample(
        position: Duration(milliseconds: posMs),
        duration: Duration(milliseconds: durMs),
        token: token,
      );

  setUp(() => sync = _RecordingSync());

  group('scrobble start', () {
    test('fires once, not once per sample', () {
      tracker()
        ..onPlaying(at(1000))
        ..onPlaying(at(2000))
        ..onPlaying(at(3000));
      expect(sync.calls, <String>['scrobbleStart']);
    });

    test('ignores samples from a superseded session', () {
      tracker().onPlaying(at(1000, token: 2));
      expect(sync.calls, isEmpty);
    });

    test('ignores a zero position from a stopped engine', () {
      tracker().onPlaying(at(0));
      expect(sync.calls, isEmpty);
    });
  });

  group('completion', () {
    test('will not mark watched on an unsettled duration', () {
      // A single sample past 90% proves nothing: VLC revises duration during
      // startup, so this ratio may be against a provisional value.
      tracker().onPlaying(at(3500000));
      expect(sync.calls, <String>['scrobbleStart']);
    });

    test('marks watched once the duration has settled', () {
      final t = tracker()
        ..onPlaying(at(1000))
        ..onPlaying(at(2000)) // duration now seen twice: settled
        ..onPlaying(at(3400000));
      expect(sync.calls, <String>['scrobbleStart', 'markWatched']);
      expect(t.markedWatched, isTrue);
    });

    test('marks watched exactly once however many samples cross the line', () {
      tracker()
        ..onPlaying(at(1000))
        ..onPlaying(at(2000))
        ..onPlaying(at(3400000))
        ..onPlaying(at(3500000))
        ..onPlaying(at(3590000));
      expect(sync.calls.where((c) => c == 'markWatched'), hasLength(1));
    });

    test('a revised duration restarts settling rather than marking', () {
      tracker()
        ..onPlaying(at(1000, durMs: 100000))
        ..onPlaying(at(95000, durMs: 3600000));
      expect(sync.calls, <String>['scrobbleStart']);
    });
  });

  group('session identity on the terminal write', () {
    // The terminal writes are queued and replayed until they land, so each one
    // has to say which viewing it belongs to. Without it the outbox cannot
    // tell a replay of this session apart from a genuinely new one: it either
    // collapses two separate viewings into one entry, or queues the same write
    // twice and counts the play twice on Trakt.
    test('markWatched carries a session key', () {
      tracker()
        ..onPlaying(at(1000))
        ..onPlaying(at(2000))
        ..onPlaying(at(3400000));
      expect(sync.calls, <String>['scrobbleStart', 'markWatched']);
      expect(sync.terminalSessionKeys.single, isNotEmpty);
    });

    test('scrobbleStop carries a session key', () {
      tracker()
        ..onPlaying(at(1000))
        ..onPlaying(at(2000))
        ..finish();
      expect(sync.calls, <String>['scrobbleStart', 'scrobbleStop']);
      expect(sync.terminalSessionKeys.single, isNotEmpty);
    });

    test('a different session gets a different key', () {
      PlaybackTracker(
          read: read,
          item: item,
          episode: null,
          videoUrl: 'https://example.com/show/1',
          token: 9,
        )
        ..onPlaying(at(1000, token: 9))
        ..onPlaying(at(2000, token: 9))
        ..finish();
      final first = sync.terminalSessionKeys.single;

      tracker()
        ..onPlaying(at(1000))
        ..onPlaying(at(2000))
        ..finish();
      expect(sync.terminalSessionKeys, hasLength(2));
      expect(sync.terminalSessionKeys.last, isNot(first));
    });

    // The regression. `token` is `_VlcPlayerScreenState._token`, a plain State
    // field declared `int _token = 0` and incremented once per `_start()`.
    // Every player launch builds a fresh State, so the first — and usually
    // only — resolution of *every* viewing yields 1. Two viewings of the same
    // episode on two launches therefore arrived at the outbox under the same
    // key; while the first was still queued (offline, or a tracker outage) the
    // second, newer terminal write was dropped as a duplicate of it and the
    // queue later delivered the older progress, resuming the user tens of
    // minutes behind where they actually got to.
    test('two launches of the same episode do not share a session key', () {
      String keyForOneLaunch() {
        sync = _RecordingSync();
        // token == 1: exactly what a fresh _VlcPlayerScreenState produces on
        // its first and only _start().
        PlaybackTracker(
            read: read,
            item: item,
            episode: null,
            videoUrl: 'https://example.com/show/1',
            token: 1,
          )
          ..onPlaying(at(1000, token: 1))
          ..onPlaying(at(2000, token: 1))
          ..finish();
        return sync.terminalSessionKeys.single!;
      }

      expect(keyForOneLaunch(), isNot(keyForOneLaunch()));
    });
  });

  group('history roll-forward at completion', () {
    // Crossing 90% is when the viewer is done with this episode, and the
    // credits are exactly when they back out. Leaving the rollover to
    // end-of-media left Continue Watching offering the finished episode
    // at 92%.
    final episodes = [
      Episode(name: 'One', url: 'https://ex/e1', season: 1, episode: 1),
      Episode(name: 'Two', url: 'https://ex/e2', season: 1, episode: 2),
    ];
    final series = MultimediaItem(
      title: 'Show',
      url: 'https://ex/show',
      posterUrl: '',
      contentType: MultimediaContentType.series,
      episodes: episodes,
    );
    final film = MultimediaItem(
      title: 'Film',
      url: 'https://ex/film',
      posterUrl: '',
      contentType: MultimediaContentType.movie,
    );

    late _RecordingHistory history;
    late _StubEpisodeWatch episodeWatch;

    PlaybackTracker trackerFor(
      MultimediaItem item, {
      Episode? episode,
      String videoUrl = '',
    }) => PlaybackTracker(
      // Completion touches four providers. Dispatching on the requested type
      // keeps the fakes honest: anything unexpected throws rather than
      // silently answering with the wrong one.
      read: <T>(provider) {
        if (identical(provider, syncManagerProvider)) return sync as T;
        if (history is T) return history as T;
        if (episodeWatch is T) return episodeWatch as T;
        return _StubHistoryRepo() as T;
      },
      item: item,
      episode: episode,
      videoUrl: videoUrl,
      token: 3,
    );

    void complete(PlaybackTracker t) => t
      ..onPlaying(at(1000))
      ..onPlaying(at(2000))
      ..onPlaying(at(3400000));

    setUp(() {
      history = _RecordingHistory();
      episodeWatch = _StubEpisodeWatch();
    });

    test('points Continue Watching at the next episode', () {
      complete(trackerFor(series, episode: episodes.first));
      expect(history.savedEpisodeUrls, <String>['https://ex/e2']);
      expect(history.removed, isEmpty);
    });

    test('drops the series only once the last episode is located', () {
      complete(trackerFor(series, episode: episodes.last));
      expect(history.savedEpisodeUrls, isEmpty);
      expect(history.removed, <String>['https://ex/show']);
    });

    test('an unlocatable episode makes no claim about the series', () {
      // removeFromHistory cascades over every per-episode row for the title,
      // so "cannot find the current episode" must never reach it.
      complete(
        trackerFor(
          series,
          episode: Episode(name: 'Ghost', url: 'https://ex/e99'),
          videoUrl: 'https://ex/e99',
        ),
      );
      expect(history.savedEpisodeUrls, isEmpty);
      expect(history.removed, isEmpty);
    });

    test('a finished film leaves Continue Watching', () {
      complete(trackerFor(film));
      expect(history.removed, <String>['https://ex/film']);
    });

    test('rolls forward once, however many samples cross the line', () {
      final t = trackerFor(series, episode: episodes.first);
      complete(t);
      t
        ..onPlaying(at(3500000))
        ..onPlaying(at(3590000));
      expect(history.savedEpisodeUrls, hasLength(1));
    });
  });

  group('terminal event', () {
    // The old path emits scrobbleStop at dispose and can then also emit
    // markWatched from saveProgress - two terminal events for one episode.
    test('markWatched suppresses the stop', () {
      final t = tracker()
        ..onPlaying(at(1000))
        ..onPlaying(at(2000))
        ..onPlaying(at(3400000));
      t.finish();
      expect(sync.calls, <String>['scrobbleStart', 'markWatched']);
    });

    test('an unfinished session stops instead', () {
      final t = tracker()
        ..onPlaying(at(1000))
        ..onPlaying(at(600000));
      t.finish();
      expect(sync.calls, <String>['scrobbleStart', 'scrobbleStop']);
    });

    test('finishing twice still emits one event', () {
      final t = tracker()
        ..onPlaying(at(1000))
        ..onPlaying(at(600000));
      t.finish();
      t.finish();
      expect(sync.calls.where((c) => c == 'scrobbleStop'), hasLength(1));
    });

    test('a session that never played emits nothing', () {
      tracker().finish();
      expect(sync.calls, isEmpty);
    });

    test('samples after finish are ignored', () {
      final t = tracker()..onPlaying(at(1000));
      t.finish();
      t.onPlaying(at(3500000));
      expect(sync.calls, <String>['scrobbleStart', 'scrobbleStop']);
    });
  });

  group('pause and resume', () {
    test('pause reports once, resume restarts', () {
      final t = tracker()..onPlaying(at(1000));
      t.onPaused();
      t.onPaused();
      t.onPlaying(at(2000));
      expect(sync.calls, <String>[
        'scrobbleStart',
        'scrobblePause',
        'scrobbleStart',
      ]);
    });

    test('a watched session stops scrobbling pauses', () {
      final t = tracker()
        ..onPlaying(at(1000))
        ..onPlaying(at(2000))
        ..onPlaying(at(3400000));
      t.onPaused();
      expect(sync.calls, <String>['scrobbleStart', 'markWatched']);
    });

    test('pause before anything played reports nothing', () {
      tracker().onPaused();
      expect(sync.calls, isEmpty);
    });
  });
}

/// Records the history writes completion makes, without touching Hive.
class _RecordingHistory implements WatchHistory {
  final List<String> savedEpisodeUrls = <String>[];
  final List<String> removed = <String>[];

  @override
  Future<void> saveProgress(
    MultimediaItem item,
    int position,
    int duration, {
    String? lastStreamUrl,
    String? lastEpisodeUrl,
    int? season,
    int? episode,
    String? episodeTitle,
    String? episodePosterUrl,
  }) async {
    savedEpisodeUrls.add(lastEpisodeUrl ?? '');
  }

  @override
  Future<void> removeFromHistory(String url) async => removed.add(url);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('not needed: ${invocation.memberName}');
}

/// rollForwardHistory reads the next episode's stored numbers back before
/// rewriting them; an empty row is all these tests need.
class _StubHistoryRepo implements HistoryRepository {
  @override
  int getEpisodePosition(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => 0;

  @override
  int getEpisodeDuration(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('not needed: ${invocation.memberName}');
}

/// Swallows the local watched flag; the assertions are about history.
class _StubEpisodeWatch implements EpisodeWatchRepository {
  @override
  Future<void> setWatched(
    String mainUrl,
    Episode episode,
    bool watched,
  ) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('not needed: ${invocation.memberName}');
}
