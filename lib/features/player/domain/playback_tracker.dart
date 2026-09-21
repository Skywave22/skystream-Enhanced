/// Completion and remote scrobbling for one playback session.
///
/// Every write here is an irreversible write to somebody's account: Trakt,
/// Simkl, MyAnimeList and AniList all accept a "watched" signal and none of
/// them offers an undo through this app. Getting one of these rules wrong
/// corrupts real user data the app cannot repair.
///
///   1. The latch is set before the write is dispatched, never after. An
///      `await` between the check and the set is a window in which a second
///      call passes the same check.
///   2. Exactly one terminal event per session — `markWatched` or
///      `scrobbleStop`, never both. Two of them either duplicate the Trakt play
///      or resurrect the episode in Continue Watching.
///   3. Completion is judged only from a sample taken while playing. At `ended`
///      and `stopped` libVLC reports position 0, so a ratio computed then is 0
///      and the branch silently never fires.
///   4. The duration must have settled first. VLC revises its reported duration
///      during startup, and a 90% ratio against a provisional duration marks a
///      title watched seconds after it opens.
///   5. The latch never resets on failover or retry; only a genuinely new
///      episode gets a new session.
///   6. The terminal write is durable and therefore needs an identity.
///      `SyncManager` persists `markWatched`/`scrobbleStop` and replays them
///      until they land, so a session key travels with the write: a replay must
///      collapse onto the queued entry while a genuinely new viewing queues a
///      new one.
library;

import 'dart:async';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/logger/app_logger.dart';
import '../../../core/storage/episode_watch_repository.dart';
import '../../library/presentation/history_provider.dart';
import '../../tracking/data/sync_manager.dart';
import 'episode_navigator.dart';
import 'playback_progress.dart';
import 'stream_resolver.dart' show ProviderReader;

/// How many consecutive identical readings make a duration trustworthy.
const int _kDurationSettleTicks = 2;

class PlaybackTracker {
  PlaybackTracker({
    required this.read,
    required this.item,
    required this.episode,
    required this.videoUrl,
    required this.token,
  });

  final ProviderReader read;
  final MultimediaItem item;
  final Episode? episode;

  /// The route's token, only ever used as [nextEpisodeFor]'s last resort for
  /// locating the current episode when [episode] is null.
  final String videoUrl;

  /// Session identity, matching [ProgressSample.token]. Samples from a
  /// superseded session are ignored rather than attributed to this one.
  final int token;

  bool _scrobbleStarted = false;
  bool _markedWatched = false;
  bool _finished = false;
  bool _pauseReported = false;

  Duration? _settledDuration;
  Duration? _durationCandidate;
  int _durationTicks = 0;

  /// The most recent sample taken while playback was genuinely running. The
  /// only thing any terminal decision is allowed to consult.
  ProgressSample? _lastGood;

  bool get markedWatched => _markedWatched;

  bool get _isSeries =>
      item.contentType == MultimediaContentType.series ||
      item.contentType == MultimediaContentType.anime;

  /// Feed every sample observed while `state == playing`.
  void onPlaying(ProgressSample sample) {
    if (_finished || sample.token != token) return;
    if (!sample.isWritable) return;

    _lastGood = sample;
    _settleDuration(sample.duration);

    if (!_scrobbleStarted) {
      _scrobbleStarted = true;
      _dispatch(
        'scrobbleStart',
        (m) => m.scrobbleStart(item, episode, sample.fraction),
      );
    } else if (_pauseReported) {
      _pauseReported = false;
      if (!_markedWatched) {
        _dispatch(
          'scrobbleStart (resume)',
          (m) => m.scrobbleStart(item, episode, sample.fraction),
        );
      }
    }

    _evaluateCompletion(sample);
  }

  /// Feed the transition into `paused` — not `buffering`, which VLC enters and
  /// leaves constantly and which is not a user pause.
  void onPaused() {
    if (_finished || !_scrobbleStarted || _markedWatched) return;
    if (_pauseReported) return;
    final sample = _lastGood;
    if (sample == null) return;
    _pauseReported = true;
    _dispatch(
      'scrobblePause',
      (m) => m.scrobblePause(item, episode, sample.fraction),
    );
  }

  /// Ends the session, emitting at most one terminal event.
  ///
  /// Safe to call more than once; only the first call does anything.
  void finish() {
    if (_finished) return;
    _finished = true;

    final sample = _lastGood;
    // A media that ran to its end may never have produced a sample past the
    // 90% line if the duration settled late, so give completion one last look
    // before falling back to a stop.
    if (sample != null && !_markedWatched) _evaluateCompletion(sample);

    if (_markedWatched) return; // markWatched was the terminal event.
    if (!_scrobbleStarted || sample == null) return;

    _dispatch(
      'scrobbleStop',
      (m) => m.scrobbleStop(item, episode, sample.fraction, sessionKey: _key),
    );
  }

  /// This session's identity, handed to [SyncManager] so its outbox can tell a
  /// retry of this write apart from a genuinely new viewing: stable across the
  /// retries, different across sessions.
  ///
  /// Deliberately not [token] on its own. [token] counts stream resolutions
  /// inside one player screen and every launch builds a fresh screen, so the
  /// first — usually only — resolution of every viewing produced the same
  /// value; two viewings of the same episode on two launches then shared an
  /// outbox key and the newer terminal write was dropped as a duplicate of the
  /// queued one.
  ///
  /// [token] is kept on the end for diagnostics only. The wall clock plus the
  /// process-local [_sessionSeq] carries the uniqueness, so the value holds
  /// even if the clock stands still or steps backwards.
  late final String _key =
      '${DateTime.now().microsecondsSinceEpoch}-${++_sessionSeq}-$token';

  /// Tie-breaker for two trackers minted inside the same microsecond.
  static int _sessionSeq = 0;

  /// VLC revises duration during startup, so a value is only trusted once it
  /// has been reported unchanged several times running.
  void _settleDuration(Duration duration) {
    if (duration <= Duration.zero) return;
    if (_settledDuration != null) return;
    if (_durationCandidate == duration) {
      _durationTicks++;
      if (_durationTicks >= _kDurationSettleTicks) _settledDuration = duration;
      return;
    }
    _durationCandidate = duration;
    _durationTicks = 1;
  }

  void _evaluateCompletion(ProgressSample sample) {
    if (_markedWatched) return;
    if (_settledDuration == null) return;
    if (sample.duration != _settledDuration) return;
    if (!sample.isComplete) return;

    // Set first, dispatch second. Everything below is fire-and-forget, so any
    // await here would leave the gate open.
    _markedWatched = true;

    final currentEpisode = episode;
    if (_isSeries && currentEpisode != null) {
      unawaited(
        read(episodeWatchRepositoryProvider)
            .setWatched(item.url, currentEpisode, true)
            .catchError((Object e) {
              talker.error('Failed to save local watched state', e);
            }),
      );
    }

    _dispatch(
      'markWatched',
      (m) => m.markWatched(item, currentEpisode, sessionKey: _key),
    );
    _rollHistoryForward(currentEpisode);
  }

  /// Moves Continue Watching off the thing that has just finished.
  ///
  /// Here rather than in the screen's advance path because 90% is the moment
  /// the viewer is done with this episode, and the credits are exactly when
  /// they back out: leaving the rollover to end-of-media left the finished
  /// episode on offer at 92%.
  ///
  /// Runs at most once per session — [_markedWatched] gates the only caller —
  /// and is idempotent with the advance path, which asks the same question
  /// again when the media actually ends.
  void _rollHistoryForward(Episode? currentEpisode) {
    if (_isSeries) {
      final lookup = nextEpisodeFor(
        item: item,
        current: currentEpisode,
        videoUrl: videoUrl,
      );
      final next = lookup.next;
      if (next != null) {
        rollForwardHistory(read: read, item: item, next: next);
        return;
      }
      // Not located in the list means "don't know", not "the series ended".
      // The delete below cascades across every per-episode row for this title.
      if (!lookup.isFinalEpisode) return;
    }

    unawaited(
      read(watchHistoryProvider.notifier)
          .removeFromHistory(item.url)
          .catchError((Object e) {
            talker.error('Failed to clear finished item from history', e);
          }),
    );
  }

  void _dispatch(String label, Future<void> Function(SyncManager) call) {
    unawaited(
      call(read(syncManagerProvider)).catchError((Object e) {
        talker.error('$label failed', e);
      }),
    );
  }
}
