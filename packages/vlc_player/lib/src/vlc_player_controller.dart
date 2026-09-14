import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleListener, AppLifecycleState, WidgetsBinding;

import 'vlc_media_info.dart';
import 'vlc_http_headers.dart';
import 'vlc_media_source.dart';
import 'vlc_player_config.dart';
import 'vlc_media_stats.dart';
import 'vlc_player_controller_internals.dart';
import 'vlc_player_error.dart';
import 'vlc_player_value.dart';
import 'vlc_video_fit.dart';

/// Playlist repeat behavior used by `VlcPlayerController.setPlaylist`.
enum VlcPlaylistLoopMode {
  /// Stop at the beginning or end of the playlist.
  none,

  /// Repeat the current playlist item when it ends.
  loopOne,

  /// Wrap to the first or last item when advancing past an edge.
  loopAll,
}

/// Controls a `VlcPlayer` and exposes playback state.
///
/// A controller can be configured before it is attached to a widget. Calls to
/// [setMedia] or [setPlaylist] are remembered and applied when the native
/// player is created. Playback commands such as [play] and [pause] require the
/// controller to be attached to a `VlcPlayer`.
abstract class VlcPlayerController extends ValueNotifier<VlcPlayerValue> {
  /// Creates a controller.
  ///
  /// Use [mediaSource] when an initial media item should be applied when the
  /// native player is created.
  /// Prefer [config] over hand-written [options]: it is typed, documented, and
  /// spells the VLC flags for you. When both are given, [config] is expanded
  /// first and [options] appended, so a raw option always wins over the
  /// generated equivalent.
  factory VlcPlayerController({
    VlcMediaSource? mediaSource,
    bool autoPlay = false,
    VlcPlayerConfig? config,
    List<String> options = const <String>[],
    Duration? eventThrottleInterval,
    Duration stallIndicatorDelay = const Duration(milliseconds: 1000),
  }) {
    return _VlcPlayerController(
      mediaSource: mediaSource,
      autoPlay: autoPlay,
      options: <String>[...?config?.toOptions(), ...options],
      eventThrottleInterval: eventThrottleInterval,
      stallIndicatorDelay: stallIndicatorDelay,
      // The nullable value, not the resolved one: the platform default is
      // read at the moment it is needed so a const config cannot freeze it.
      configuredBackgroundPolicy: config?.backgroundPolicy,
    );
  }

  VlcPlayerController._() : super(const VlcPlayerValue());

  /// Whether the initially configured media source should start playback
  /// immediately.
  bool get autoPlay;

  /// VLC instance options applied when the native player is created.
  List<String> get options;

  /// Optional interval used to coalesce progress-only native events.
  ///
  /// When set to a positive duration, updates that only change playback
  /// position, media duration, or buffering progress are delivered at most once
  /// per interval. State, readiness, track metadata, volume, speed, and errors
  /// still notify listeners immediately. The default `null` keeps every
  /// distinct native value update visible immediately.
  Duration? get eventThrottleInterval;

  /// How long the position clock may stand still on a playing player before
  /// [VlcPlayerValue.isStalled] is raised.
  ///
  /// The default of one second is not a taste choice. The desktop backends
  /// poll libVLC every 500 ms and the host may throttle events on top of that
  /// ([eventThrottleInterval]), so two consecutive snapshots of healthy
  /// playback can legitimately be up to poll-plus-throttle apart. A delay
  /// shorter than that reads the gap between polls as a stall and flickers a
  /// spinner over a video that is playing fine. Anything set here must stay
  /// clear of that sum.
  Duration get stallIndicatorDelay;

  /// What the controller does with playback when the app leaves the
  /// foreground, resolved against the platform default.
  ///
  /// Owned here rather than by the host screen so that every embedder of this
  /// package gets the behaviour, and so the "resume only what the policy
  /// paused" bookkeeping lives next to the state it reads.
  VlcBackgroundPolicy get backgroundPolicy;

  /// Whether this controller is currently attached to a native player instance.
  bool get isAttached;

  /// Current playlist items, or an empty list when no playlist is active.
  List<VlcMediaSource> get playlist;

  /// Current playlist index, or `null` when no playlist is active.
  int? get playlistIndex;

  /// Current playlist loop mode.
  VlcPlaylistLoopMode get playlistLoopMode;

  /// Current media source, including a pending source set before attachment.
  VlcMediaSource? get currentMediaSource;

  /// Whether [next] can move to another item without wrapping.
  bool get hasNext;

  /// Whether [previous] can move to another item without wrapping.
  bool get hasPrevious;

  /// Loads a [VlcMediaSource].
  ///
  /// Use this when the item needs HTTP headers, VLC media options, or an
  /// initial seek position. This clears any active playlist.
  Future<void> setMedia(VlcMediaSource source, {bool autoPlay = false});

  /// Loads a playlist and selects [initialIndex].
  ///
  /// [sources] must be non-empty. When [autoAdvance] is true, the controller
  /// advances after VLC reports that the current item ended. [loopMode] controls
  /// repeat and wrap behavior.
  Future<void> setPlaylist(
    List<VlcMediaSource> sources, {
    int initialIndex = 0,
    bool autoPlay = false,
    bool autoAdvance = true,
    VlcPlaylistLoopMode loopMode = VlcPlaylistLoopMode.none,
  });

  /// Moves to the next playlist item.
  ///
  /// Returns `false` when there is no next item and [playlistLoopMode] is
  /// [VlcPlaylistLoopMode.none]. Throws [StateError] when no playlist is active.
  Future<bool> next({bool autoPlay = true});

  /// Moves to the previous playlist item.
  ///
  /// Returns `false` when there is no previous item and [playlistLoopMode] is
  /// [VlcPlaylistLoopMode.none]. Throws [StateError] when no playlist is active.
  Future<bool> previous({bool autoPlay = true});

  /// Loads the playlist item at [index].
  ///
  /// Throws [StateError] when no playlist is active.
  Future<void> jumpTo(int index, {bool autoPlay = true});

  /// Appends [source] to the active playlist.
  ///
  /// Throws [StateError] when no playlist is active.
  Future<void> addToPlaylist(VlcMediaSource source);

  /// Inserts [source] into the active playlist at [index].
  ///
  /// Throws [StateError] when no playlist is active.
  Future<void> insertIntoPlaylist(int index, VlcMediaSource source);

  /// Removes the playlist item at [index].
  ///
  /// Removing the current item loads the next valid item. If the removed item
  /// was the only item, playback stops and the playlist is cleared.
  Future<void> removeFromPlaylistAt(int index, {bool autoPlay = true});

  /// Clears the active playlist and stops playback when a player is attached.
  Future<void> clearPlaylist();

  /// Shuffles the active playlist.
  ///
  /// When [seed] is provided, the shuffle order is deterministic.
  Future<void> shufflePlaylist({int? seed});

  /// Starts or resumes playback.
  Future<void> play();

  /// Pauses playback.
  Future<void> pause();

  /// Stops playback.
  Future<void> stop();

  /// Seeks to [position].
  ///
  /// [position] must be non-negative.
  Future<void> seekTo(Duration position);

  /// How many seeks have been asked for on this controller.
  ///
  /// Only ever increases, and increases the moment a seek is requested rather
  /// than when the engine acts on one. A host watching for a dead source needs
  /// that distinction: a seek freezes the reported position while the demuxer
  /// repositions and refills, and on a slow source it can stay frozen for
  /// longer than any sane "nothing is happening" threshold. Counting that as a
  /// dead source reopens the media underneath a viewer who only skipped
  /// forward. Comparing this against a remembered value tells a host the freeze
  /// it is looking at was asked for.
  int get seekRequests;

  /// Sets VLC volume.
  ///
  /// Values are clamped to VLC's `0..200` range.
  Future<void> setVolume(int volume);

  /// Sets playback speed.
  ///
  /// [speed] must be finite and greater than zero. `1.0` is normal speed.
  Future<void> setPlaybackSpeed(double speed);

  /// Changes how video is scaled inside the view, without recreating the
  /// native player. Called by `VlcPlayer` when its `fit` changes.
  Future<void> setFit(VlcVideoFit fit);

  /// Sets the audio playback delay.
  ///
  /// Positive values delay audio; negative values play audio earlier.
  Future<void> setAudioDelay(Duration delay);

  /// Sets the subtitle display delay.
  ///
  /// Positive values delay subtitles; negative values show subtitles earlier.
  Future<void> setSubtitleDelay(Duration delay);

  /// Captures the current video frame as PNG bytes.
  ///
  /// [width] and [height] must be positive when provided.
  Future<Uint8List> takeSnapshot({int? width, int? height});

  /// Returns selectable audio tracks for the current media.
  Future<List<VlcTrackDescription>> getAudioTracks();

  /// Selects an audio track by VLC track [id].
  ///
  /// Use an id returned by [getAudioTracks].
  Future<void> setAudioTrack(int id);

  /// Returns selectable embedded subtitle tracks for the current media.
  Future<List<VlcTrackDescription>> getSubtitleTracks();

  /// Selects an embedded subtitle track by VLC track [id].
  ///
  /// Use an id returned by [getSubtitleTracks].
  Future<void> setSubtitleTrack(int id);

  /// Disables subtitle rendering for the current media.
  Future<void> disableSubtitle();

  /// Asks the engine to add an external subtitle from [uri] and select it.
  ///
  /// [uri] can point to a local file or a remote subtitle URL supported by VLC.
  ///
  /// The future completing does NOT mean the track exists yet. Before
  /// attachment the request is queued and replayed on attach; after it,
  /// libVLC 3 hands the slave to the input thread, so the snapshot that
  /// follows still describes the state from before the add on all five
  /// backends. Wait for [VlcPlayerValue.trackRevision] to move, then re-read
  /// [getSubtitleTracks]; do not treat a list read straight after this call as
  /// authoritative.
  Future<void> addSubtitle(Uri uri);

  /// Returns metadata and discovered track details for the current media.
  Future<VlcMediaInfo> getMediaInfo();

  /// Returns runtime statistics for the current media session.
  Future<VlcMediaStats> getMediaStats();
}

const MethodChannel _methodChannel = MethodChannel('vlc_player');

class _VlcPlayerController extends VlcPlayerController
    implements VlcPlayerControllerInternals {
  _VlcPlayerController({
    VlcMediaSource? mediaSource,
    this.autoPlay = false,
    List<String> options = const <String>[],
    this.eventThrottleInterval,
    required this.stallIndicatorDelay,
    this.configuredBackgroundPolicy,
  }) : options = List<String>.unmodifiable(options),
       super._() {
    if (eventThrottleInterval case final interval? when interval.isNegative) {
      throw ArgumentError.value(
        eventThrottleInterval,
        'eventThrottleInterval',
        'Must not be negative.',
      );
    }
    if (stallIndicatorDelay <= Duration.zero) {
      throw ArgumentError.value(
        stallIndicatorDelay,
        'stallIndicatorDelay',
        'Must be positive.',
      );
    }
    _pendingMediaSource = mediaSource;
    _pendingAutoPlay = autoPlay;
  }

  @override
  final bool autoPlay;

  @override
  final List<String> options;

  @override
  final Duration? eventThrottleInterval;

  @override
  final Duration stallIndicatorDelay;

  /// The host's stated preference, or null to follow the platform.
  final VlcBackgroundPolicy? configuredBackgroundPolicy;

  /// Created on first attach rather than in the constructor.
  ///
  /// [AppLifecycleListener] resolves `WidgetsBinding.instance` eagerly, and a
  /// controller is legitimately built in a plain `flutter_test` `test()` with
  /// no binding at all — configuring one is not the same as playing anything.
  /// There is also nothing to pause before a native player exists.
  AppLifecycleListener? _lifecycleListener;

  /// Whether [backgroundPolicy] is what paused the current playback.
  ///
  /// The whole point of the flag: a viewer who paused by hand and then pressed
  /// Home must come back to a paused player. Resuming unconditionally is the
  /// bug this exists to prevent.
  bool _pausedForBackground = false;

  /// Whether the CURRENT media has actually reached playback.
  ///
  /// [VlcPlayerValue] merges into its predecessor, so straight after
  /// `setMedia` `value.position` still describes the media before it. This is
  /// the flag that tells the two apart, and it is what makes a re-attach able
  /// to trust the live position - see [_mediaForAttach].
  bool _hasPlayedSinceMedia = false;

  /// Whether an audio interruption is what paused the current playback, and
  /// whether it promised to end.
  ///
  /// Set only for [VlcAudioInterruption.focusLostTransient]: a call comes
  /// back, a permanent loss and a yanked pair of headphones do not.
  ///
  /// Tracked apart from [_pausedForBackground] rather than folded into it,
  /// because the two are settled by different events and the interleaving that
  /// matters gets it wrong otherwise. A call arriving and then the call UI
  /// pushing the app away leaves only this one set — the policy stakes its
  /// claim on a player it found playing, and an interrupted player is already
  /// paused — so when focus returns to a backgrounded app, the claim is handed
  /// over deliberately in [_applyInterruption] instead of being assumed.
  ///
  /// Both being set at once is harmless where it can happen, and neither
  /// resume can escape the native focus request: a play that the system
  /// refuses does not start anything, it comes straight back as another
  /// interruption.
  bool _pausedForAudioFocus = false;

  /// Whether the app is currently in the background.
  ///
  /// Distinct from [_pausedForBackground], which only records that the policy
  /// paused something. Media can be opened while the app is away - a cold
  /// magnet resolves for minutes - and that open must not start making noise.
  bool _backgrounded = false;

  int? _viewId;
  int? _textureId;
  VlcMediaSource? _pendingMediaSource;
  bool _pendingAutoPlay = false;

  /// External subtitles requested before a player instance existed.
  ///
  /// [setMedia] already tolerates being called before attachment, so callers
  /// reasonably expect [addSubtitle] to as well — otherwise every caller has to
  /// hand-roll the same "wait until attached" dance. They are flushed in order
  /// once a view or texture is attached, and dropped when new media is set.
  final List<Uri> _pendingSubtitles = <Uri>[];
  List<VlcMediaSource> _playlist = const <VlcMediaSource>[];
  int? _playlistIndex;
  bool _playlistAutoAdvance = false;
  VlcPlaylistLoopMode _playlistLoopMode = VlcPlaylistLoopMode.none;
  StreamSubscription<Object?>? _eventsSubscription;
  Timer? _eventThrottleTimer;
  VlcPlayerValue? _pendingThrottledValue;

  /// Counts down [stallIndicatorDelay] from the first snapshot whose position
  /// matched the one before it. Armed only while the engine claims to be
  /// running, and disarmed by any movement of the clock.
  Timer? _stallTimer;

  /// The position of the last native snapshot, throttled or not.
  ///
  /// Kept apart from `value.position` on purpose: under [eventThrottleInterval]
  /// the published position lags the engine by up to an interval, and a stall
  /// judged against it would see a frozen clock at every flush.
  Duration? _lastNativePosition;
  bool _isDisposed = false;

  @override
  VlcBackgroundPolicy get backgroundPolicy =>
      configuredBackgroundPolicy ??
      VlcPlayerConfig.platformDefaultBackgroundPolicy;

  @override
  bool get isAttached => _viewId != null;

  @override
  List<VlcMediaSource> get playlist => _playlist;

  @override
  int? get playlistIndex => _playlistIndex;

  @override
  VlcPlaylistLoopMode get playlistLoopMode => _playlistLoopMode;

  @override
  VlcMediaSource? get currentMediaSource => _pendingMediaSource;

  @override
  bool get hasNext => switch (_playlistIndex) {
    final int index => index + 1 < _playlist.length,
    null => false,
  };

  @override
  bool get hasPrevious => switch (_playlistIndex) {
    final int index => index > 0,
    null => false,
  };

  /// Attaches this controller to a platform-view player instance.
  @override
  Future<void> attach(int viewId) async {
    _ensureNotDisposed();
    if (_viewId == viewId) {
      return;
    }

    final oldViewId = _viewId;
    _viewId = null;
    _textureId = null;
    await _eventsSubscription?.cancel();
    _eventsSubscription = null;
    _cancelPendingThrottledValue();
    _cancelStallTimer();
    if (oldViewId != null) {
      await _disposeNativeView(oldViewId);
    }
    if (_isDisposed) {
      await _disposeNativeView(viewId);
      throw StateError('The controller has been disposed.');
    }

    _viewId = viewId;
    _eventsSubscription = EventChannel(
      'vlc_player/events/$viewId',
    ).receiveBroadcastStream().listen(_handleEvent, onError: _handleEventError);
    _ensureLifecycleListener();

    final pendingMediaSource = _pendingMediaSource;
    if (pendingMediaSource != null) {
      await _setMedia(
        _mediaForAttach(pendingMediaSource),
        autoPlay: _pendingAutoPlay,
      );
      _ensureNotDisposed();
    }
    await _flushPendingSubtitles();
  }

  /// Attaches this controller to a texture-backed player instance.
  @override
  @internal
  Future<int> attachTexturePlayer() async {
    _ensureNotDisposed();

    final existingTextureId = _textureId;
    if (_viewId != null && existingTextureId != null) {
      return existingTextureId;
    }

    final oldViewId = _viewId;
    _viewId = null;
    _textureId = null;
    await _eventsSubscription?.cancel();
    _eventsSubscription = null;
    _cancelPendingThrottledValue();
    _cancelStallTimer();
    if (oldViewId != null) {
      await _disposeNativeView(oldViewId);
    }
    _ensureNotDisposed();

    final response = await _invokeNativeMap('create', <String, Object?>{
      'options': options,
    });
    final viewId = (response?['viewId'] as num?)?.toInt();
    final textureId = (response?['textureId'] as num?)?.toInt();
    if (viewId == null || textureId == null) {
      throw StateError('vlc_player texture creation returned invalid data.');
    }
    if (_isDisposed) {
      await _disposeNativeView(viewId);
      throw StateError('The controller has been disposed.');
    }

    _viewId = viewId;
    _textureId = textureId;
    _eventsSubscription = EventChannel(
      'vlc_player/events/$viewId',
    ).receiveBroadcastStream().listen(_handleEvent, onError: _handleEventError);
    _ensureLifecycleListener();

    final pendingMediaSource = _pendingMediaSource;
    if (pendingMediaSource != null) {
      await _setMedia(
        _mediaForAttach(pendingMediaSource),
        autoPlay: _pendingAutoPlay,
      );
      _ensureNotDisposed();
    }
    await _flushPendingSubtitles();

    return textureId;
  }

  /// The media to hand a freshly attached player.
  ///
  /// A *re*-attach — the same controller picking up a surface that was torn
  /// down and rebuilt — would otherwise replay the source from the position it
  /// was originally opened at, dropping a viewer an hour into a film back at
  /// the start. The last position this controller saw is the honest answer.
  ///
  /// The configured start survives while nothing has played, which is the
  /// first attach: that is exactly when [VlcMediaSource.startPosition] carries
  /// a resume point and `value.position` is still zero.
  VlcMediaSource _mediaForAttach(VlcMediaSource source) {
    final position = value.position;
    // Only a session that actually reached playback can improve on the
    // configured start. Two traps this avoids: a viewer who rewound below
    // their resume point would otherwise be thrown forward to it again, and a
    // value sampled right after setMedia still carries the PREVIOUS media's
    // position because VlcPlayerValue merges into its predecessor.
    if (!_hasPlayedSinceMedia || position <= Duration.zero) {
      return source;
    }
    return VlcMediaSource(
      uri: source.uri,
      httpHeaders: source.httpHeaders,
      mediaOptions: source.mediaOptions,
      startPosition: position,
    );
  }

  /// Detaches and disposes the native player instance, if one is attached.
  ///
  /// [viewId] names the view the caller believes it owns; a mismatch is a
  /// no-op. Platform-view teardown is not ordered against creation — the
  /// outgoing element's `dispose` can run after the incoming one has already
  /// attached — so an unqualified call would null out a view that is playing.
  /// Null means "whatever is attached", which is all the texture path can say:
  /// it never learns the id.
  @override
  @internal
  Future<void> detach({int? viewId}) async {
    final attachedViewId = _viewId;
    if (viewId != null && attachedViewId != viewId) {
      return;
    }
    _viewId = null;
    _textureId = null;
    await _eventsSubscription?.cancel();
    _eventsSubscription = null;
    _cancelPendingThrottledValue();
    _cancelStallTimer();
    if (attachedViewId != null) {
      await _disposeNativeView(attachedViewId);
    }
  }

  /// Starts watching the application lifecycle, once.
  ///
  /// The directional callbacks rather than `onStateChange`, deliberately.
  /// `hidden` is passed through in both directions — leaving is
  /// inactive → hidden and returning is paused → hidden — so a raw state
  /// switch re-arms the background pause on the way back in and then resumes
  /// a player the viewer had stopped by hand. [AppLifecycleListener] already
  /// works out which way the app is travelling; taking its answer is cheaper
  /// than keeping a second copy of the state machine here.
  ///
  /// `onInactive` is deliberately absent. On Android it is what entering
  /// picture-in-picture looks like — the activity pauses while its window
  /// stays on screen and playing — and on desktop it is merely a window that
  /// lost focus.
  void _ensureLifecycleListener() {
    // AppLifecycleListener only reports transitions, so a controller attached
    // while the app is already away would never learn it. Seed from the
    // binding's current answer before subscribing.
    final current = WidgetsBinding.instance.lifecycleState;
    _backgrounded =
        current == AppLifecycleState.paused ||
        current == AppLifecycleState.hidden ||
        current == AppLifecycleState.detached;
    _lifecycleListener ??= AppLifecycleListener(
      onHide: _pauseForBackground,
      onPause: _pauseForBackground,
      onResume: _resumeFromBackground,
    );
  }

  void _pauseForBackground() {
    if (_isDisposed) return;
    // Recorded even when there is nothing to pause yet. Resolution can outlast
    // the app going away, and the open that follows has to know.
    _backgrounded = true;
    if (backgroundPolicy != VlcBackgroundPolicy.pause ||
        _pausedForBackground ||
        _viewId == null ||
        !value.isPlaying) {
      return;
    }
    _pausedForBackground = true;
    // Not the public pause(): that one is the user's, and clears the flag this
    // just set. Failures are swallowed because a player that has already gone
    // away has, for this purpose, done what was asked.
    unawaited(_invoke('pause').catchError((Object _) {}));
  }

  void _resumeFromBackground() {
    if (_isDisposed) return;
    _backgrounded = false;
    if (!_pausedForBackground) return;
    _pausedForBackground = false;
    if (_viewId == null) {
      return;
    }
    unawaited(_invoke('play').catchError((Object _) {}));
  }

  /// Mirrors a native audio interruption into this controller's bookkeeping.
  ///
  /// The engine is already paused, ducked or restored by the time this runs:
  /// audio focus has to be honoured in the instant it moves, not a channel
  /// round trip later. What the native side cannot answer is who owns the
  /// resume, because that depends on the app lifecycle and on
  /// [backgroundPolicy], both of which live here. So it reports, and this
  /// decides.
  ///
  /// Never through the public [play] and [pause]: those mean "the viewer
  /// decided" and clear [_pausedForBackground]. A phone call is not a
  /// decision the viewer made.
  void _applyInterruption(
    VlcAudioInterruption previous,
    VlcAudioInterruption next,
  ) {
    if (_isDisposed || previous == next) return;

    if (next != VlcAudioInterruption.none) {
      _pausedForAudioFocus = next == VlcAudioInterruption.focusLostTransient;
      return;
    }

    if (!_pausedForAudioFocus) return;
    _pausedForAudioFocus = false;
    if (_viewId == null) {
      return;
    }
    if (_backgrounded && backgroundPolicy == VlcBackgroundPolicy.pause) {
      // The call ended while the app is still away. Playing here is exactly
      // the noise nobody asked for, so the claim is handed to the background
      // policy and the trip back to the foreground settles it.
      _pausedForBackground = true;
      return;
    }
    unawaited(_invoke('play').catchError((Object _) {}));
  }

  @override
  Future<void> setMedia(VlcMediaSource source, {bool autoPlay = false}) async {
    _ensureNotDisposed();
    // New media invalidates side-car subtitles queued for the old one.
    _pendingSubtitles.clear();
    final previousPlaylist = _playlist;
    final previousPlaylistIndex = _playlistIndex;
    final previousPlaylistAutoAdvance = _playlistAutoAdvance;
    final previousPlaylistLoopMode = _playlistLoopMode;
    final previousMediaSource = _pendingMediaSource;
    final previousAutoPlay = _pendingAutoPlay;
    _clearPlaylist();
    try {
      await _setMedia(source, autoPlay: autoPlay);
    } catch (_) {
      _playlist = previousPlaylist;
      _playlistIndex = previousPlaylistIndex;
      _playlistAutoAdvance = previousPlaylistAutoAdvance;
      _playlistLoopMode = previousPlaylistLoopMode;
      _pendingMediaSource = previousMediaSource;
      _pendingAutoPlay = previousAutoPlay;
      rethrow;
    }
  }

  @override
  Future<void> setPlaylist(
    List<VlcMediaSource> sources, {
    int initialIndex = 0,
    bool autoPlay = false,
    bool autoAdvance = true,
    VlcPlaylistLoopMode loopMode = VlcPlaylistLoopMode.none,
  }) async {
    _ensureNotDisposed();
    if (sources.isEmpty) {
      throw ArgumentError.value(sources, 'sources', 'Must be non-empty.');
    }
    RangeError.checkValidIndex(initialIndex, sources, 'initialIndex');

    final previousPlaylist = _playlist;
    final previousPlaylistIndex = _playlistIndex;
    final previousPlaylistAutoAdvance = _playlistAutoAdvance;
    final previousPlaylistLoopMode = _playlistLoopMode;
    final previousMediaSource = _pendingMediaSource;
    final previousAutoPlay = _pendingAutoPlay;
    _playlist = List<VlcMediaSource>.unmodifiable(sources);
    _playlistIndex = initialIndex;
    _playlistAutoAdvance = autoAdvance;
    _playlistLoopMode = loopMode;
    try {
      await _setMedia(_playlist[initialIndex], autoPlay: autoPlay);
    } catch (_) {
      _playlist = previousPlaylist;
      _playlistIndex = previousPlaylistIndex;
      _playlistAutoAdvance = previousPlaylistAutoAdvance;
      _playlistLoopMode = previousPlaylistLoopMode;
      _pendingMediaSource = previousMediaSource;
      _pendingAutoPlay = previousAutoPlay;
      rethrow;
    }
  }

  @override
  Future<bool> next({bool autoPlay = true}) {
    return _moveInPlaylist(1, autoPlay: autoPlay);
  }

  @override
  Future<bool> previous({bool autoPlay = true}) {
    return _moveInPlaylist(-1, autoPlay: autoPlay);
  }

  @override
  Future<void> jumpTo(int index, {bool autoPlay = true}) async {
    _ensureActivePlaylist();
    RangeError.checkValidIndex(index, _playlist, 'index');
    if (index == _playlistIndex) {
      return;
    }
    await _loadPlaylistIndex(index, autoPlay: autoPlay);
  }

  @override
  Future<void> addToPlaylist(VlcMediaSource source) {
    return insertIntoPlaylist(_playlist.length, source);
  }

  @override
  Future<void> insertIntoPlaylist(int index, VlcMediaSource source) async {
    _ensureActivePlaylist();
    RangeError.checkValueInInterval(index, 0, _playlist.length, 'index');
    final currentIndex = _playlistIndex!;
    final nextPlaylist = <VlcMediaSource>[..._playlist]..insert(index, source);
    _playlist = List<VlcMediaSource>.unmodifiable(nextPlaylist);
    if (index <= currentIndex) {
      _playlistIndex = currentIndex + 1;
    }
  }

  @override
  Future<void> removeFromPlaylistAt(int index, {bool autoPlay = true}) async {
    _ensureActivePlaylist();
    RangeError.checkValidIndex(index, _playlist, 'index');

    final previousPlaylist = _playlist;
    final previousPlaylistIndex = _playlistIndex;
    final previousMediaSource = _pendingMediaSource;
    final previousAutoPlay = _pendingAutoPlay;
    final currentIndex = previousPlaylistIndex!;
    final nextPlaylist = <VlcMediaSource>[..._playlist]..removeAt(index);

    if (nextPlaylist.isEmpty) {
      await _stopIfAttached();
      _clearPlaylist();
      _pendingMediaSource = null;
      _pendingAutoPlay = false;
      return;
    }

    _playlist = List<VlcMediaSource>.unmodifiable(nextPlaylist);
    if (index < currentIndex) {
      _playlistIndex = currentIndex - 1;
      return;
    }
    if (index > currentIndex) {
      _playlistIndex = currentIndex;
      return;
    }

    final nextIndex = math.min(index, nextPlaylist.length - 1);
    _playlistIndex = nextIndex;
    try {
      await _setMedia(_playlist[nextIndex], autoPlay: autoPlay);
    } catch (_) {
      _playlist = previousPlaylist;
      _playlistIndex = previousPlaylistIndex;
      _pendingMediaSource = previousMediaSource;
      _pendingAutoPlay = previousAutoPlay;
      rethrow;
    }
  }

  @override
  Future<void> clearPlaylist() async {
    _ensureNotDisposed();
    if (_playlistIndex == null) {
      return;
    }
    await _stopIfAttached();
    _clearPlaylist();
    _pendingMediaSource = null;
    _pendingAutoPlay = false;
  }

  @override
  Future<void> shufflePlaylist({int? seed}) async {
    _ensureActivePlaylist();
    final currentSource = currentMediaSource;
    final random = seed == null ? math.Random() : math.Random(seed);
    final nextPlaylist = <VlcMediaSource>[..._playlist]..shuffle(random);
    _playlist = List<VlcMediaSource>.unmodifiable(nextPlaylist);
    _playlistIndex = currentSource == null
        ? 0
        : _playlist
              .indexOf(currentSource)
              .clamp(0, _playlist.length - 1)
              .toInt();
  }

  Future<bool> _moveInPlaylist(int delta, {required bool autoPlay}) async {
    _ensureActivePlaylist();
    final index = _playlistIndex!;

    final nextIndex = index + delta;
    if (nextIndex < 0 || nextIndex >= _playlist.length) {
      if (_playlistLoopMode != VlcPlaylistLoopMode.loopAll) {
        return false;
      }
      return _loadPlaylistIndex(
        nextIndex < 0 ? _playlist.length - 1 : 0,
        autoPlay: autoPlay,
      );
    }

    return _loadPlaylistIndex(nextIndex, autoPlay: autoPlay);
  }

  Future<bool> _loadPlaylistIndex(
    int nextIndex, {
    required bool autoPlay,
  }) async {
    final index = _playlistIndex;
    if (index == null) {
      throw StateError('No playlist has been set.');
    }

    _playlistIndex = nextIndex;
    final previousMediaSource = _pendingMediaSource;
    final previousAutoPlay = _pendingAutoPlay;
    try {
      await _setMedia(_playlist[nextIndex], autoPlay: autoPlay);
    } catch (_) {
      _playlistIndex = index;
      _pendingMediaSource = previousMediaSource;
      _pendingAutoPlay = previousAutoPlay;
      rethrow;
    }
    return true;
  }

  Future<void> _setMedia(
    VlcMediaSource source, {
    required bool autoPlay,
  }) async {
    _ensureNotDisposed();
    // A fresh media has not played yet, whatever the merged value still says.
    // The stall clock goes with it: the position it was watching belongs to
    // the media on its way out, and the opening buffer of the new one is the
    // startup spinner's job, not this one's.
    _hasPlayedSinceMedia = false;
    _cancelStallTimer();
    // Opening while the app is away must not start audio nobody can stop:
    // there is no notification and no lock-screen control behind this yet.
    // The policy's claim is staked here so the return trip resumes it.
    if (autoPlay &&
        _backgrounded &&
        backgroundPolicy == VlcBackgroundPolicy.pause) {
      autoPlay = false;
      _pausedForBackground = true;
    }
    _pendingMediaSource = source;
    _pendingAutoPlay = autoPlay;

    final viewId = _viewId;
    if (viewId == null) {
      return;
    }

    await _invokeNative<void>(
      'setSource',
      _sourceArguments(viewId, source, autoPlay: autoPlay),
    );
  }

  void _clearPlaylist() {
    _playlist = const <VlcMediaSource>[];
    _playlistIndex = null;
    _playlistAutoAdvance = false;
    _playlistLoopMode = VlcPlaylistLoopMode.none;
  }

  void _ensureActivePlaylist() {
    _ensureNotDisposed();
    if (_playlistIndex == null) {
      throw StateError('No playlist has been set.');
    }
  }

  // play/pause/stop are the deliberate-intent entry points — the on-screen
  // button, a remote, and in due course the media session and the audio-focus
  // handler. Any of them settles the background question on its own terms, so
  // they clear the policy's claim on the next resume: a viewer who pressed
  // play from a notification while the app was hidden has said what they want.
  @override
  Future<void> play() {
    // The background claim goes, because the viewer has settled the question
    // the trip back to the foreground would otherwise answer.
    //
    // The audio-focus claim stays. "Play" and "resume when the call ends" are
    // the same wish, and on Android a play made during a call is refused
    // outright — that refusal comes back as an interruption, and the delayed
    // grant that follows is the only thing that will ever start this playing.
    _pausedForBackground = false;
    return _invoke('play');
  }

  @override
  Future<void> pause() {
    _clearAutomaticPauseClaims();
    // A paused player is not stalled, it is paused. The flag itself is cleared
    // by the paused snapshot when it arrives; what must not happen is the
    // timer firing in the gap before it and painting a spinner over a still
    // frame the viewer asked for.
    _cancelStallTimer();
    return _invoke('pause');
  }

  @override
  Future<void> stop() {
    _clearAutomaticPauseClaims();
    _cancelStallTimer();
    return _invoke('stop');
  }

  /// Drops every claim that would otherwise start playback on its own.
  ///
  /// Asking for silence answers both questions at once: a viewer who pauses
  /// while the app is hidden, or during a phone call, must not have the film
  /// started again by the return trip or by the end of the call.
  void _clearAutomaticPauseClaims() {
    _pausedForBackground = false;
    _pausedForAudioFocus = false;
  }

  int _seekRequests = 0;

  @override
  int get seekRequests => _seekRequests;

  @override
  Future<void> seekTo(Duration position) {
    if (position.isNegative) {
      throw ArgumentError.value(position, 'position', 'Must be non-negative.');
    }
    _seekRequests += 1;
    // After a rebuffer, the gap between a seek and the first frame at the new
    // position is the stall a viewer feels most, so the clock restarts here
    // rather than waiting for a snapshot to notice nothing moved.
    //
    // The comparison baseline moves to the target as well. Every backend
    // reports the requested time straight after a seek, before a frame has
    // been decoded there; measured against the OLD position that report looks
    // like movement and would disarm the timer, pushing the spinner out by a
    // whole extra delay. This is a private baseline for the clock, never the
    // published position - a viewer who scrubs still sees the engine's own
    // position, and the host's resume point never records a place the engine
    // did not reach.
    _cancelStallTimer();
    if (_isRunning((_pendingThrottledValue ?? value).state)) {
      _lastNativePosition = position;
      _armStallTimer();
    }
    return _invoke('seekTo', <String, Object?>{
      'position': position.inMilliseconds,
    });
  }

  @override
  Future<void> setVolume(int volume) {
    return _invoke('setVolume', <String, Object?>{
      'volume': volume.clamp(0, 200),
    });
  }

  @override
  Future<void> setPlaybackSpeed(double speed) {
    if (!speed.isFinite || speed <= 0) {
      throw ArgumentError.value(
        speed,
        'speed',
        'Must be finite and greater than zero.',
      );
    }
    return _invoke('setPlaybackSpeed', <String, Object?>{'speed': speed});
  }

  @override
  Future<void> setFit(VlcVideoFit fit) {
    return _invoke('setFit', <String, Object?>{'fit': fit.name});
  }

  @override
  Future<void> setAudioDelay(Duration delay) {
    return _invoke('setAudioDelay', <String, Object?>{
      'delay': delay.inMicroseconds,
    });
  }

  @override
  Future<void> setSubtitleDelay(Duration delay) {
    return _invoke('setSubtitleDelay', <String, Object?>{
      'delay': delay.inMicroseconds,
    });
  }

  @override
  Future<Uint8List> takeSnapshot({int? width, int? height}) async {
    if (width != null && width <= 0) {
      throw ArgumentError.value(width, 'width', 'Must be positive.');
    }
    if (height != null && height <= 0) {
      throw ArgumentError.value(height, 'height', 'Must be positive.');
    }
    final data = await _invokeFor<Uint8List>('takeSnapshot', <String, Object?>{
      'width': ?width,
      'height': ?height,
    });
    if (data == null || data.isEmpty) {
      throw StateError('vlc_player snapshot returned no image data.');
    }
    return data;
  }

  @override
  Future<List<VlcTrackDescription>> getAudioTracks() async {
    final tracks = await _invokeFor<List<Object?>>('getAudioTracks');
    return _trackDescriptionsFrom(tracks);
  }

  @override
  Future<void> setAudioTrack(int id) {
    if (id < 0) {
      throw ArgumentError.value(id, 'id', 'Must be non-negative.');
    }
    return _invoke('setAudioTrack', <String, Object?>{'id': id});
  }

  @override
  Future<List<VlcTrackDescription>> getSubtitleTracks() async {
    final tracks = await _invokeFor<List<Object?>>('getSubtitleTracks');
    return _trackDescriptionsFrom(tracks);
  }

  @override
  Future<void> setSubtitleTrack(int id) {
    if (id < 0) {
      throw ArgumentError.value(id, 'id', 'Must be non-negative.');
    }
    return _invoke('setSubtitleTrack', <String, Object?>{'id': id});
  }

  @override
  Future<void> disableSubtitle() => _invoke('disableSubtitle');

  @override
  Future<void> addSubtitle(Uri uri) async {
    _ensureNotDisposed();
    final value = uri.toString();
    if (value.isEmpty) {
      throw ArgumentError.value(uri, 'uri', 'Must be non-empty.');
    }
    if (_viewId == null) {
      _pendingSubtitles.add(uri);
      return;
    }
    await _invoke('addSubtitle', <String, Object?>{'uri': value});
  }

  /// Applies subtitles queued before attachment, in the order requested.
  ///
  /// A failure here must not take down attachment: the video is playable
  /// without a side-car subtitle, so a bad URI is dropped rather than thrown.
  Future<void> _flushPendingSubtitles() async {
    if (_pendingSubtitles.isEmpty || _viewId == null) {
      return;
    }
    final pending = List<Uri>.of(_pendingSubtitles);
    _pendingSubtitles.clear();
    for (final uri in pending) {
      if (_isDisposed || _viewId == null) {
        return;
      }
      try {
        await _invoke('addSubtitle', <String, Object?>{'uri': uri.toString()});
      } catch (_) {
        // Ignored on purpose - see above.
      }
    }
  }

  @override
  Future<VlcMediaInfo> getMediaInfo() async {
    final info = await _invokeFor<Map<Object?, Object?>>('getMediaInfo');
    return VlcMediaInfo.fromMap(info ?? const <Object?, Object?>{});
  }

  @override
  Future<VlcMediaStats> getMediaStats() async {
    final stats = await _invokeFor<Map<Object?, Object?>>('getMediaStats');
    return VlcMediaStats.fromMap(stats ?? const <Object?, Object?>{});
  }

  Future<void> _invoke(String method, [Map<String, Object?>? arguments]) {
    return _invokeFor<void>(method, arguments);
  }

  Future<T?> _invokeFor<T>(String method, [Map<String, Object?>? arguments]) {
    return _invokeNative<T>(method, _attachedArguments(arguments));
  }

  Future<void> _stopIfAttached() {
    if (_viewId == null) {
      return Future<void>.value();
    }
    return _invoke('stop');
  }

  Map<String, Object?> _attachedArguments([Map<String, Object?>? arguments]) {
    _ensureNotDisposed();
    final viewId = _viewId;
    if (viewId == null) {
      throw StateError('The controller is not attached to a VlcPlayer.');
    }

    return <String, Object?>{'viewId': viewId, ...?arguments};
  }

  /// Builds every `setSource` payload, so headers can never desync from the
  /// media they belong to.
  ///
  /// HTTP headers are translated to libVLC options **here**, once, rather than
  /// in each of the five native backends. libVLC can transmit only User-Agent
  /// and Referer (see vlc_http_headers.dart); the natives are handed the raw
  /// map as well, but only for mechanisms that are genuinely platform-specific.
  Map<String, Object?> _sourceArguments(
    int viewId,
    VlcMediaSource source, {
    required bool autoPlay,
  }) {
    final headerOptions = vlcHeaderOptions(source.httpHeaders);
    final mediaOptions = <String>[...headerOptions, ...source.mediaOptions];

    assert(() {
      final dropped = unsupportedVlcHeaders(source.httpHeaders);
      if (dropped.isNotEmpty) {
        debugPrint(
          'vlc_player: libVLC cannot send these headers, so they were dropped '
          'for ${source.uri}: ${dropped.join(', ')}. Proxy the media and '
          'inject them upstream if the server requires them.',
        );
      }
      return true;
    }());

    return <String, Object?>{
      'viewId': viewId,
      'uri': source.uri.toString(),
      'autoPlay': autoPlay,
      'httpHeaders': source.httpHeaders,
      if (mediaOptions.isNotEmpty) 'mediaOptions': mediaOptions,
      if (source.startPosition > Duration.zero)
        'startPosition': source.startPosition.inMilliseconds,
    };
  }

  Future<T?> _invokeNative<T>(String method, Map<String, Object?> arguments) {
    return _mapPlatformException(
      () => _methodChannel.invokeMethod<T>(method, arguments),
    );
  }

  Future<Map<String, Object?>?> _invokeNativeMap(
    String method,
    Map<String, Object?> arguments,
  ) {
    return _mapPlatformException(
      () => _methodChannel.invokeMapMethod<String, Object?>(method, arguments),
    );
  }

  static Future<T> _mapPlatformException<T>(
    Future<T> Function() operation,
  ) async {
    try {
      return await operation();
    } on PlatformException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        VlcPlayerException.fromPlatformException(error),
        stackTrace,
      );
    }
  }

  static List<VlcTrackDescription> _trackDescriptionsFrom(Object? value) {
    if (value is! Iterable) {
      return const <VlcTrackDescription>[];
    }
    return value
        .whereType<Map>()
        .map(
          (track) =>
              VlcTrackDescription.fromMap(track.cast<Object?, Object?>()),
        )
        .toList(growable: false);
  }

  Future<void> _disposeNativeView(int viewId) {
    return _methodChannel.invokeMethod<void>('dispose', <String, Object?>{
      'viewId': viewId,
    });
  }

  void _handleEvent(Object? event) {
    if (_isDisposed) {
      return;
    }
    final previousValue = _pendingThrottledValue ?? value;
    final nextValue = _observeStall(
      VlcPlayerValue.fromEvent(event, previousValue),
    );
    _setValueFromEvent(previousValue, nextValue);
    _applyInterruption(previousValue.interruption, nextValue.interruption);
    if (_playlistAutoAdvance &&
        previousValue.state != VlcPlaybackState.ended &&
        nextValue.state == VlcPlaybackState.ended) {
      if (_playlistLoopMode == VlcPlaylistLoopMode.loopOne) {
        final current = _pendingMediaSource;
        if (current != null) {
          _runAutoAdvance(_setMedia(current, autoPlay: true));
        }
      } else if (hasNext || _playlistLoopMode == VlcPlaylistLoopMode.loopAll) {
        _runAutoAdvance(next().then<void>((_) {}));
      }
    }
  }

  void _runAutoAdvance(Future<void> operation) {
    unawaited(
      operation.catchError((Object error, StackTrace stackTrace) {
        _handleAutoAdvanceError(error);
      }),
    );
  }

  void _handleAutoAdvanceError(Object error) {
    if (_isDisposed) {
      return;
    }
    final playerError = error is VlcPlayerException
        ? error.error
        : error is PlatformException
        ? VlcPlayerError.fromPlatformException(error)
        : VlcPlayerError(
            code: VlcPlayerErrorCode.playbackError,
            message: error.toString(),
          );
    _setPlayerError(playerError);
  }

  void _handleEventError(Object error) {
    if (_isDisposed) {
      return;
    }
    final playerError = error is PlatformException
        ? VlcPlayerError.fromPlatformException(error)
        : VlcPlayerError(
            code: VlcPlayerErrorCode.eventChannelError,
            message: error.toString(),
          );
    _setPlayerError(playerError);
  }

  void _setPlayerError(VlcPlayerError playerError) {
    _cancelPendingThrottledValue();
    _cancelStallTimer();
    value = value.copyWith(
      state: VlcPlaybackState.error,
      error: playerError,
      errorDescription: playerError.message,
    );
  }

  void _setValueFromEvent(
    VlcPlayerValue previousValue,
    VlcPlayerValue nextValue,
  ) {
    if (nextValue == previousValue) {
      return;
    }
    if (!_shouldThrottleEvent(previousValue, nextValue)) {
      _setValueImmediately(nextValue);
      return;
    }
    _pendingThrottledValue = nextValue;
    _eventThrottleTimer ??= Timer(eventThrottleInterval!, _flushThrottledValue);
  }

  bool _shouldThrottleEvent(
    VlcPlayerValue previousValue,
    VlcPlayerValue nextValue,
  ) {
    final interval = eventThrottleInterval;
    if (interval == null || interval.inMicroseconds == 0) {
      return false;
    }
    return previousValue.state == nextValue.state &&
        previousValue.volume == nextValue.volume &&
        previousValue.playbackSpeed == nextValue.playbackSpeed &&
        previousValue.audioDelay == nextValue.audioDelay &&
        previousValue.subtitleDelay == nextValue.subtitleDelay &&
        previousValue.isReady == nextValue.isReady &&
        previousValue.isSeekable == nextValue.isSeekable &&
        previousValue.isLive == nextValue.isLive &&
        // A stall flag changing is the whole event, not a progress tick that
        // can wait for the next flush.
        previousValue.isStalled == nextValue.isStalled &&
        // Likewise a track switch or a track list changing shape: the panel
        // that asked for it is waiting on this exact value, and it is not a
        // progress tick.
        previousValue.activeAudioTrackId == nextValue.activeAudioTrackId &&
        previousValue.activeSubtitleTrackId ==
            nextValue.activeSubtitleTrackId &&
        previousValue.trackRevision == nextValue.trackRevision &&
        previousValue.interruption == nextValue.interruption &&
        previousValue.videoSize == nextValue.videoSize &&
        previousValue.error == nextValue.error &&
        previousValue.errorDescription == nextValue.errorDescription;
  }

  void _setValueImmediately(VlcPlayerValue nextValue) {
    _cancelPendingThrottledValue();
    value = nextValue;
  }

  void _flushThrottledValue() {
    final pendingValue = _pendingThrottledValue;
    _eventThrottleTimer = null;
    _pendingThrottledValue = null;
    if (!_isDisposed && pendingValue != null) {
      value = pendingValue;
    }
  }

  void _cancelPendingThrottledValue() {
    _eventThrottleTimer?.cancel();
    _eventThrottleTimer = null;
    _pendingThrottledValue = null;
  }

  /// Reads the position clock in [next] and returns what should be published.
  ///
  /// Runs on every native snapshot, before the equality and throttle gates,
  /// because a snapshot identical to the last one is precisely the evidence a
  /// stall is made of - it must arm the timer even though it publishes
  /// nothing.
  ///
  /// "Moved" rather than "advanced", deliberately: a seek backwards lands the
  /// clock below where it was and a later snapshot from there is progress. A
  /// strictly-greater test would hold the spinner up until playback overtook
  /// the pre-seek position.
  VlcPlayerValue _observeStall(VlcPlayerValue next) {
    final moved = _lastNativePosition != next.position;
    _lastNativePosition = next.position;
    // Set here rather than on publish so that throttled progress ticks count:
    // under an event throttle the first snapshot with a real position is
    // usually coalesced, and a flag that only immediate publishes could set
    // would leave a re-attach unable to trust the live position and this
    // clock unable to arm at all.
    if (next.position > Duration.zero) _hasPlayedSinceMedia = true;

    if (!_isRunning(next.state)) {
      // Paused, stopped, ended, error, opening: none of these is a stall, and
      // the flag clears in this same publish rather than a frame later.
      _cancelStallTimer();
      return next.isStalled ? next.copyWith(isStalled: false) : next;
    }
    if (moved) {
      // Movement clears the flag - and RESTARTS the countdown rather than
      // cancelling it. Every native except Android suppresses a snapshot
      // identical to the last one it sent, so a real freeze does not arrive
      // as a repeated position: it arrives as silence. The only way to see
      // that silence is a deadline measured from the last snapshot that
      // moved. Gated the same way as the frozen path: a clock that has never
      // run - a live stream, the pre-first-frame buffer - is not stalling.
      if (_hasPlayedSinceMedia) {
        _restartStallTimer();
      } else {
        _cancelStallTimer();
      }
      return next.isStalled ? next.copyWith(isStalled: false) : next;
    }
    // A clock that has not moved yet is not a stall: a live stream may never
    // report movement, and before the first frame the startup buffer owns the
    // spinner. Only a clock that once ran and has now stopped qualifies.
    if (_hasPlayedSinceMedia) {
      _armStallTimer();
    }
    return next;
  }

  /// Whether [state] claims the engine is producing frames, which is the only
  /// claim a frozen clock can contradict.
  static bool _isRunning(VlcPlaybackState state) {
    return state == VlcPlaybackState.playing ||
        state == VlcPlaybackState.buffering;
  }

  /// Starts the countdown if it is not already running. Never restarts it: on
  /// a native that repeats a frozen position (Android), the stall began at the
  /// first frozen snapshot, not the latest.
  void _armStallTimer() {
    _stallTimer ??= Timer(stallIndicatorDelay, _markStalled);
  }

  /// Restarts the countdown from now. Used on every moved snapshot, so that
  /// the deadline always means "nothing has moved for stallIndicatorDelay" -
  /// which is what a stall looks like on the natives that go silent.
  void _restartStallTimer() {
    _stallTimer?.cancel();
    _stallTimer = Timer(stallIndicatorDelay, _markStalled);
  }

  void _cancelStallTimer() {
    _stallTimer?.cancel();
    _stallTimer = null;
  }

  void _markStalled() {
    _stallTimer = null;
    if (_isDisposed) {
      return;
    }
    // Both copies, or the next throttle flush overwrites the flag with the
    // pre-stall snapshot it was holding.
    final pending = _pendingThrottledValue;
    if (pending != null) {
      _pendingThrottledValue = pending.copyWith(isStalled: true);
    }
    if (!value.isStalled) {
      value = value.copyWith(isStalled: true);
    }
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw StateError('The controller has been disposed.');
    }
  }

  /// Disposes the controller and releases the attached native player.
  @override
  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
    final viewId = _viewId;
    _viewId = null;
    _textureId = null;
    _eventsSubscription?.cancel();
    _eventsSubscription = null;
    _cancelPendingThrottledValue();
    _cancelStallTimer();
    if (viewId != null) {
      unawaited(_disposeNativeView(viewId));
    }
    super.dispose();
  }
}
