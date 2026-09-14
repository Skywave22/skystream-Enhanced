/// A durable, de-duplicating outbox for the tracking writes that must survive
/// a network flap.
///
/// The terminal tracking events - "this episode is watched", "playback stopped
/// here" - are emitted at exactly the moment a phone is most likely to lose the
/// network, and a lost write loses the episode permanently while the app's own
/// list still shows it watched.
///
/// [SyncOutbox.enqueue] writes the entry to storage before it attempts the
/// network, so a process kill between the two costs nothing.
///
/// Delivery is recorded per service, not per event: Trakt's `scrobble/stop` is
/// not idempotent, so an entry carries the set of service id-prefixes that have
/// already confirmed it and a retry only goes to the remainder.
///
/// Enqueue de-duplicates on (op, item url, season/episode, episode url,
/// session). The session component has to be unique per viewing, not per
/// screen, or the second of two viewings loses its write to the first.
///
/// Only terminal events are queued. `scrobbleStart` and `scrobblePause`
/// describe where the user is right now, so replaying a two-hour-old "paused at
/// 12%" would overwrite a newer resume point with stale data; losing one of
/// those costs nothing.
///
/// The queue is bounded by [maxEntries], [maxAgeMs] and [maxAttempts], and a
/// queued stop expires far sooner than a queued mark
/// ([SyncOutbox.maxStopAgeMs]). `markWatched` is a monotone fact;
/// `scrobbleStop` carries a position and the wire format has no field for
/// when, so Trakt stamps `paused_at` with its own receipt time and a late
/// replay overwrites the point a newer viewing, often on another device,
/// already recorded.
library;

import 'dart:async';
import 'dart:convert';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/logger/app_logger.dart';
import '../../../core/storage/storage_service.dart';

/// The tracking writes the outbox is allowed to replay.
///
/// Deliberately only the terminal ones; see the library comment.
enum SyncOp { markWatched, scrobbleStop }

/// What one fan-out to the tracking services achieved.
class SyncDispatchResult {
  const SyncDispatchResult({required this.delivered, required this.failed});

  /// Service `idPrefix`es that accepted the write on this attempt.
  final Set<String> delivered;

  /// Service `idPrefix`es that were owed the write and did not accept it.
  final Set<String> failed;

  /// Nothing left to retry.
  bool get complete => failed.isEmpty;
}

/// Performs one fan-out, skipping every service in [alreadyDelivered].
typedef SyncSender =
    Future<SyncDispatchResult> Function(
      SyncOp op,
      MultimediaItem item,
      Episode? episode,
      double progress,
      Set<String> alreadyDelivered,
    );

/// Somewhere to keep one string across restarts.
abstract class SyncOutboxStore {
  String? read();
  Future<void> write(String? value);
}

/// The production store: a single JSON string in the Hive settings box.
///
/// [_resolve] is a closure rather than the service itself because
/// `storageServiceProvider` throws until `StorageService.init` has run, and the
/// outbox must not turn that into a crash at provider-build time. Both methods
/// degrade to "no persistence" if storage is unavailable.
class HiveSyncOutboxStore implements SyncOutboxStore {
  HiveSyncOutboxStore(this._resolve);

  static const String storageKey = 'tracking_sync_outbox_v1';

  final StorageService Function() _resolve;

  @override
  String? read() {
    try {
      return _resolve().getString(storageKey);
    } catch (e) {
      talker.error('SyncOutbox: could not read the queue', e);
      return null;
    }
  }

  @override
  Future<void> write(String? value) async {
    try {
      await _resolve().setString(storageKey, value);
    } catch (e) {
      talker.error('SyncOutbox: could not persist the queue', e);
    }
  }
}

/// One queued tracking write.
class SyncOutboxEntry {
  SyncOutboxEntry({
    required this.key,
    required this.op,
    required this.item,
    required this.episode,
    required this.progress,
    required this.enqueuedAtMs,
    this.attempts = 0,
    this.nextAttemptMs = 0,
    Set<String>? delivered,
  }) : delivered = delivered ?? <String>{};

  /// Identity used for de-duplication.
  final String key;
  final SyncOp op;
  final MultimediaItem item;
  final Episode? episode;
  final double progress;
  final int enqueuedAtMs;

  int attempts;
  int nextAttemptMs;

  /// Service `idPrefix`es that have already confirmed this write. Never
  /// re-sent to.
  final Set<String> delivered;

  /// Only the fields a tracking write actually addresses the title by. A full
  /// [MultimediaItem.toJson] drags episode lists, cast and stream candidates
  /// into the queue; those can be megabytes and none of them is used here.
  Map<String, dynamic> toJson() => {
    'key': key,
    'op': op.name,
    'progress': progress,
    'at': enqueuedAtMs,
    'attempts': attempts,
    'next': nextAttemptMs,
    'delivered': delivered.toList(),
    'item': {
      'title': item.title,
      'url': item.url,
      'type': item.contentType.name,
      'tmdbId': item.tmdbId,
      'imdbId': item.imdbId,
      'syncData': item.syncData,
    },
    if (episode != null)
      'episode': {
        'name': episode!.name,
        'url': episode!.url,
        'season': episode!.season,
        'number': episode!.episode,
      },
  };

  static SyncOutboxEntry? fromJson(Map<String, dynamic> json) {
    try {
      final rawItem = Map<String, dynamic>.from(json['item'] as Map);
      final rawEpisode = json['episode'] == null
          ? null
          : Map<String, dynamic>.from(json['episode'] as Map);
      final rawSyncData = rawItem['syncData'];
      return SyncOutboxEntry(
        key: json['key'] as String,
        op: SyncOp.values.byName(json['op'] as String),
        item: MultimediaItem(
          title: (rawItem['title'] as String?) ?? '',
          url: (rawItem['url'] as String?) ?? '',
          posterUrl: '',
          contentType: MultimediaItem.parseContentType(
            rawItem['type'] as String?,
          ),
          tmdbId: (rawItem['tmdbId'] as num?)?.toInt(),
          imdbId: rawItem['imdbId'] as String?,
          syncData: rawSyncData == null
              ? null
              : Map<String, String>.from(rawSyncData as Map),
        ),
        episode: rawEpisode == null
            ? null
            : Episode(
                name: (rawEpisode['name'] as String?) ?? '',
                url: (rawEpisode['url'] as String?) ?? '',
                season: (rawEpisode['season'] as num?)?.toInt() ?? 0,
                episode: (rawEpisode['number'] as num?)?.toInt() ?? 0,
              ),
        progress: (json['progress'] as num?)?.toDouble() ?? 1.0,
        enqueuedAtMs: (json['at'] as num?)?.toInt() ?? 0,
        attempts: (json['attempts'] as num?)?.toInt() ?? 0,
        nextAttemptMs: (json['next'] as num?)?.toInt() ?? 0,
        delivered: ((json['delivered'] as List?) ?? const [])
            .map((e) => e.toString())
            .toSet(),
      );
    } catch (e) {
      // A single unreadable row must not cost the user the rest of the queue.
      talker.error('SyncOutbox: dropping an unreadable queue entry', e);
      return null;
    }
  }
}

/// Builds the de-duplication identity for a write.
///
/// [session] is the identity the emitter minted for one viewing: two genuinely
/// separate viewings of the same episode get separate entries, while a repeat
/// emission inside one session collapses onto the pending one. It is the
/// caller's job to make that string unique per viewing - see
/// `PlaybackTracker._key`, which mints one per tracker rather than reusing a
/// counter that restarts at 1 on every launch.
///
/// The episode is addressed by url as well as by season/episode number,
/// because both numbers default to 0 ([Episode.season], [Episode.episode]): a
/// provider that returns an unnumbered episode list would otherwise collapse
/// every episode of the series onto one key.
String syncOutboxKey(
  SyncOp op,
  MultimediaItem item,
  Episode? episode,
  String? session,
) =>
    '${op.name}|${item.url}|${episode?.season ?? -1}x'
    '${episode?.episode ?? -1}|${episode?.url ?? ''}|${session ?? ''}';

class SyncOutbox {
  SyncOutbox({
    required SyncOutboxStore store,
    DateTime Function()? clock,
    Stream<void>? onOnline,
    this.maxEntries = 100,
    this.maxAttempts = 20,
    this.maxAgeMs = 7 * 24 * 60 * 60 * 1000,
    this.maxStopAgeMs = 60 * 60 * 1000,
    this.baseBackoff = const Duration(seconds: 30),
    this.maxBackoff = const Duration(hours: 2),
    this.autoRetry = true,
  }) : _store = store,
       _clock = clock ?? DateTime.now,
       _onOnline = onOnline;

  final SyncOutboxStore _store;
  final DateTime Function() _clock;
  final Stream<void>? _onOnline;

  /// Hard cap on queued entries. A long offline stretch drops the *oldest*
  /// entries, because a two-week-old scrobble is worth less than tonight's.
  final int maxEntries;

  /// Give-up point for an entry that keeps failing (a write no service will
  /// ever accept, e.g. a title none of them can address).
  final int maxAttempts;

  final int maxAgeMs;

  /// Age cap for [SyncOp.scrobbleStop] only.
  ///
  /// An hour covers what the outbox exists for - a handover between networks,
  /// a tunnel, a lift, a router rebooting - and stays inside the window in
  /// which the same title could plausibly have been watched somewhere else.
  /// Dropping the stop is the cheap failure: this device's own resume point
  /// lives in local history either way. Delivering it late destroys a newer
  /// position on every device.
  ///
  /// Never applied above [maxAgeMs]; the smaller of the two wins.
  final int maxStopAgeMs;

  final Duration baseBackoff;
  final Duration maxBackoff;

  /// Schedule the next due retry with a [Timer]. Off in unit tests, which
  /// drive [drain] directly against an injected clock.
  final bool autoRetry;

  final List<SyncOutboxEntry> _entries = <SyncOutboxEntry>[];
  SyncSender? _send;
  Future<void>? _loaded;
  Future<void>? _started;
  Future<void>? _drainInFlight;
  bool _disposed = false;
  Timer? _retryTimer;
  StreamSubscription<void>? _onlineSub;

  /// Queued entries, oldest first. For tests and diagnostics.
  List<SyncOutboxEntry> get entries => List.unmodifiable(_entries);

  int get length => _entries.length;

  /// Loads whatever survived the last run and immediately tries to deliver it.
  Future<void> start(SyncSender send) {
    _send = send;
    _onlineSub ??= _onOnline?.listen(
      (_) => unawaited(drain()),
      // A connectivity backend that is missing or throwing must not take the
      // outbox down with it; the backoff timer still covers recovery.
      onError: (Object _) {},
    );
    return _started ??= _ensureLoaded().then((_) => drain());
  }

  /// Completes once the replay [start] kicked off has finished. [SyncManager]
  /// starts the outbox from its constructor, which cannot await; this is how
  /// anything that needs the replay to have happened waits for it.
  Future<void> get started => _started ?? Future<void>.value();

  Future<void> _ensureLoaded() {
    return _loaded ??= Future<void>(() async {
      final raw = _store.read();
      if (raw == null || raw.isEmpty) return;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! List) return;
        for (final row in decoded) {
          if (row is! Map) continue;
          final entry = SyncOutboxEntry.fromJson(
            Map<String, dynamic>.from(row),
          );
          if (entry != null) _entries.add(entry);
        }
      } catch (e) {
        talker.error('SyncOutbox: queue unreadable, starting empty', e);
        _entries.clear();
      }
      _prune();
    });
  }

  /// Persists [op] and then attempts to deliver it.
  ///
  /// Returns once the entry is durable — the delivery attempt itself is not
  /// awaited, so a caller on the player's teardown path is never blocked on a
  /// network round trip.
  Future<void> enqueue(
    SyncOp op,
    MultimediaItem item,
    Episode? episode,
    double progress, {
    String? session,
  }) async {
    if (_disposed) return;
    await _ensureLoaded();

    final key = syncOutboxKey(op, item, episode, session);
    if (_entries.any((e) => e.key == key)) {
      // The same write is already pending. Queuing it twice is how a Trakt
      // play gets counted twice.
      talker.debug('SyncOutbox: $key already queued, not duplicating');
      return;
    }

    final now = _clock().millisecondsSinceEpoch;
    _entries.add(
      SyncOutboxEntry(
        key: key,
        op: op,
        item: item,
        episode: episode,
        progress: progress,
        enqueuedAtMs: now,
      ),
    );
    while (_entries.length > maxEntries) {
      final dropped = _entries.removeAt(0);
      talker.error(
        'SyncOutbox: queue full at $maxEntries, dropped ${dropped.key}',
      );
    }
    await _persist();
    unawaited(drain());
  }

  /// Attempts every entry whose backoff has elapsed.
  ///
  /// Concurrent callers are coalesced onto the one run rather than dropped, so
  /// awaiting this always means "a drain completed after I asked" — two
  /// overlapping drains would send the same entry twice.
  Future<void> drain() {
    if (_disposed || _send == null) return Future<void>.value();
    return _drainInFlight ??= _drain().whenComplete(() {
      _drainInFlight = null;
    });
  }

  Future<void> _drain() async {
    await _ensureLoaded();
    _prune();

    final now = _clock().millisecondsSinceEpoch;
    // Snapshot: an enqueue during the drain must not be walked mid-iteration.
    final due = _entries
        .where((e) => e.nextAttemptMs <= now)
        .toList(growable: false);

    var dirty = false;
    for (final entry in due) {
      if (_disposed) break;
      if (!_entries.contains(entry)) continue;
      dirty = true;
      entry.attempts++;
      SyncDispatchResult result;
      try {
        result = await _send!(
          entry.op,
          entry.item,
          entry.episode,
          entry.progress,
          entry.delivered,
        );
      } catch (e) {
        talker.error('SyncOutbox: ${entry.key} threw', e);
        result = const SyncDispatchResult(
          delivered: <String>{},
          failed: <String>{'*'},
        );
      }
      entry.delivered.addAll(result.delivered);
      if (result.complete) {
        _entries.remove(entry);
        continue;
      }
      if (entry.attempts >= maxAttempts) {
        talker.error(
          'SyncOutbox: giving up on ${entry.key} after ${entry.attempts} '
          'attempts; still owed by ${result.failed.join(', ')}',
        );
        _entries.remove(entry);
        continue;
      }
      entry.nextAttemptMs = _clock().millisecondsSinceEpoch + _backoff(entry);
    }

    if (dirty) await _persist();
    _scheduleRetry();
  }

  int _backoff(SyncOutboxEntry entry) {
    var ms = baseBackoff.inMilliseconds;
    for (var i = 1; i < entry.attempts; i++) {
      ms *= 2;
      if (ms >= maxBackoff.inMilliseconds) return maxBackoff.inMilliseconds;
    }
    return ms;
  }

  void _prune() {
    final now = _clock().millisecondsSinceEpoch;
    final stopCap = maxStopAgeMs < maxAgeMs ? maxStopAgeMs : maxAgeMs;
    _entries.removeWhere((e) {
      // A stop is a resume point, and a resume point goes off.
      final cap = e.op == SyncOp.scrobbleStop ? stopCap : maxAgeMs;
      final stale = e.enqueuedAtMs < now - cap;
      if (stale) {
        talker.error(
          'SyncOutbox: dropping ${e.key}, older than the ${cap}ms age cap for '
          '${e.op.name}',
        );
      }
      return stale;
    });
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!autoRetry || _disposed || _entries.isEmpty) return;
    final now = _clock().millisecondsSinceEpoch;
    final soonest = _entries
        .map((e) => e.nextAttemptMs)
        .reduce((a, b) => a < b ? a : b);
    final delay = soonest - now;
    _retryTimer = Timer(
      Duration(milliseconds: delay < 0 ? 0 : delay),
      () => unawaited(drain()),
    );
  }

  Future<void> _persist() {
    if (_entries.isEmpty) return _store.write(null);
    return _store.write(
      jsonEncode(_entries.map((e) => e.toJson()).toList(growable: false)),
    );
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    unawaited(_onlineSub?.cancel());
    _onlineSub = null;
  }
}
