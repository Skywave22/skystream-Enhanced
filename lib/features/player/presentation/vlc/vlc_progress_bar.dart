import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:vlc_player/vlc_player.dart';

import '../../../skip/data/skip_service.dart';
import '../widgets/player_stream_widgets.dart';

/// The seek bar for the VLC engine.
///
/// Thin by design: it holds only the drag position and the seek latch, and
/// renders through the shared [PlayerScrubber], so the overlay cannot drift
/// from the design the other engine gets.
///
/// It listens to the controller directly rather than through Riverpod, so a
/// position tick rebuilds this widget and nothing above it.
///
/// The latch: after a seek the controller keeps publishing the engine's own
/// position (a faked one would poison the resume point writer), so for up to a
/// snapshot round-trip the thumb would jump back to where playback was. This
/// widget holds the seek target in its place until the engine has evidently
/// honoured the seek, the media stops, or a timeout longer than the
/// controller's stall delay passes - so a genuine post-seek stall shows the
/// spinner with the thumb still on the target. Relative D-pad steps chain from
/// the latched target as a side effect, because the bar reads its start value
/// from what is displayed.
class VlcProgressBar extends StatefulWidget {
  const VlcProgressBar({
    this.bufferedFraction,
    required this.controller,
    this.isTv = false,
    this.isLive = false,
    this.skipSegments = const <SkipSegment>[],
    this.displayPosition,
    this.focusNode,
    this.onSeekStart,
    this.onSeekEnd,
    super.key,
  });

  final VlcPlayerController controller;

  /// How much of the media has been fetched ahead of the playhead, 0..1.
  ///
  /// A notifier so a stats sample repaints the band alone. Null on hosts that
  /// do not measure it, and the band then stays empty.
  final ValueListenable<double>? bufferedFraction;

  /// Ten-foot sizing, passed straight to [PlayerScrubber], where the numbers
  /// live.
  final bool isTv;

  /// Decided by the app from the item and URL, not by the engine.
  ///
  /// libVLC derives its own `isLive` as "no duration and not seekable", which
  /// is false for any live stream with a DVR window: those report a
  /// `timeShiftBufferDepth` and are seekable, so the engine calls them VOD and
  /// the bar renders an absolute timeline over the shift window. The app knows
  /// better from the manifest and the content type.
  final bool isLive;

  /// Painted as bands on the track so the viewer can see an intro coming.
  final List<SkipSegment> skipSegments;

  /// Where this bar publishes the position it is *showing*, for a clock drawn
  /// outside it.
  ///
  /// Not the engine's position: the whole point of the latch below is that
  /// those two disagree for the length of a drag and for a round trip after
  /// it. A desktop clock reading the controller directly would sit at the old
  /// time while the thumb stood at the new one, which is exactly what a viewer
  /// reads as a seek that did not take.
  ///
  /// Owned by the caller and written here, the way the screen owns the lock
  /// notifier the controls write. Null where nothing outside draws a clock.
  final ValueNotifier<Duration>? displayPosition;

  final FocusNode? focusNode;

  /// Called when a drag begins, so the overlay can hold its chrome open.
  final VoidCallback? onSeekStart;

  /// Called with the position handed to the engine, so the overlay can restart
  /// its hide timer and count its next relative step from the seek that just
  /// happened rather than from the one it made itself. Fires for a pointer
  /// release and for a D-pad burst, whose Left/Right presses the bar coalesces
  /// into one seek.
  ///
  /// Exactly one end follows each [onSeekStart], with a null target when the
  /// bar gave the seek up instead of committing it: the overlay holds its
  /// chrome open between the two, and a start with no end pins the bars up for
  /// the rest of the session.
  final void Function(Duration? target)? onSeekEnd;

  @override
  State<VlcProgressBar> createState() => _VlcProgressBarState();
}

class _VlcProgressBarState extends State<VlcProgressBar> {
  /// Set only while the user is dragging. The engine keeps reporting its own
  /// position during a scrub, and showing that would fight the thumb.
  Duration? _dragTo;

  /// The seek target handed to the engine, shown in place of the published
  /// position until [_onControllerValue] or [_pendingTimeout] releases it.
  Duration? _pendingSeek;

  /// The published position at commit: the origin the seek moved away from,
  /// so a tick can be judged as "moved past the target" rather than merely
  /// "moved".
  Duration? _pendingFrom;

  Timer? _pendingTimeout;

  /// Whether [VlcProgressBar.onSeekStart] has been reported without its end.
  bool _seeking = false;

  /// How close the engine's read-back must land to count as arrived. Seeks
  /// land on a keyframe, not on the millisecond asked for.
  static const Duration _seekLatchTolerance = Duration(milliseconds: 750);

  /// Must exceed [VlcPlayerController.stallIndicatorDelay]: a seek the engine
  /// is slow to honour raises `isStalled` at that delay, and the spinner
  /// should appear over a thumb that is still on the target.
  Duration get _latchTimeout =>
      widget.controller.stallIndicatorDelay + const Duration(milliseconds: 500);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerValue);
    // The clock's own seed covers the frame this runs after; this is what
    // corrects it if the bar was handed a notifier another controller filled.
    _publishAfterFrame();
  }

  /// The position this bar is showing: the finger, then a seek the engine has
  /// not caught up with, then the engine. The one rule, so [build] and
  /// [VlcProgressBar.displayPosition] cannot answer differently.
  Duration get _shown =>
      _dragTo ?? _pendingSeek ?? widget.controller.value.position;

  /// Hands the current answer to the outside clock.
  ///
  /// Called from every place that changes one of the three inputs, and all of
  /// them are outside a build - a gesture callback, the controller's
  /// notification, a timer - so notifying listeners here can never be a write
  /// during build.
  void _publish() {
    if (!mounted) return;
    widget.displayPosition?.value = _shown;
  }

  /// [_publish], for the callers that run inside a build.
  ///
  /// A notifier written during a build rebuilds its listeners during that same
  /// build, and the clock is one of them. [didUpdateWidget] is the only such
  /// caller, and a frame of the outgoing engine's position on the way into a
  /// new one costs nothing.
  void _publishAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _publish());
  }

  @override
  void didUpdateWidget(VlcProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_onControllerValue);
    widget.controller.addListener(_onControllerValue);
    // New media, new engine: whatever was latched was a target for the old
    // one. The build that follows this call already reads the cleared state.
    _clearLatch();
    _endSeek(null);
    _publishAfterFrame();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerValue);
    _pendingTimeout?.cancel();
    super.dispose();
  }

  /// Reports the start of a drag or a D-pad burst, at most once per seek.
  void _beginSeek() {
    if (_seeking) return;
    _seeking = true;
    widget.onSeekStart?.call();
  }

  /// Reports the end of the seek [_beginSeek] opened - [target] committed, or
  /// null if it was given up - and never twice for the same one.
  void _endSeek(Duration? target) {
    if (!_seeking) return;
    _seeking = false;
    widget.onSeekEnd?.call(target);
  }

  /// Reports the end of a seek this bar can no longer commit, and lets the
  /// frozen thumb go with it.
  ///
  /// [PlayerScrubber] nulls `onChangeEnd` the frame `canSeek` goes false, so
  /// the end the burst was promised can never arrive from below - which
  /// happens on every failover, recovery and episode advance, where the
  /// duration drops back to zero under the finger.
  void _abandonSeek() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_dragTo != null) setState(() => _dragTo = null);
      _endSeek(null);
      _publish();
    });
  }

  /// Hands [target] to the engine and latches it for display.
  void _commitSeek(Duration target) {
    _pendingFrom = widget.controller.value.position;
    _pendingSeek = target;
    _pendingTimeout?.cancel();
    _pendingTimeout = Timer(_latchTimeout, _releaseLatch);
    widget.controller.seekTo(target);
    setState(() => _dragTo = null);
    _publish();
  }

  /// Evaluated on every published value while a seek is latched.
  void _onControllerValue() {
    final target = _pendingSeek;
    final from = _pendingFrom;
    if (target == null || from == null) {
      // No latch, so the engine's position is the one being shown and every
      // tick moves the clock.
      _publish();
      return;
    }
    final value = widget.controller.value;
    if (_seekHonoured(value, target: target, from: from) ||
        !_stillPlayable(value)) {
      _releaseLatch();
    }
  }

  /// Whether [value] shows the engine has taken the seek: it landed within
  /// tolerance of [target], or it has moved past the target in the direction
  /// of the seek. A tick that merely continues from [from], or one somewhere
  /// between origin and target, holds the latch - after a chained burst that
  /// may be the previous seek landing rather than this one.
  static bool _seekHonoured(
    VlcPlayerValue value, {
    required Duration target,
    required Duration from,
  }) {
    final position = value.position;
    if ((position - target).abs() <= _seekLatchTolerance) return true;
    if (target == from) return false;
    final travelled = position - from;
    final asked = target - from;
    return travelled.isNegative == asked.isNegative &&
        travelled.abs() >= asked.abs();
  }

  /// A latch is only meaningful while the engine may still arrive at the
  /// target. Paused is fine - a paused seek still lands - but a stopped, ended
  /// or errored engine never will, and neither will one whose duration has
  /// gone back to zero because the media changed under it.
  static bool _stillPlayable(VlcPlayerValue value) {
    if (value.duration <= Duration.zero) return false;
    return switch (value.state) {
      VlcPlaybackState.idle ||
      VlcPlaybackState.stopped ||
      VlcPlaybackState.ended ||
      VlcPlaybackState.error => false,
      VlcPlaybackState.opening ||
      VlcPlaybackState.buffering ||
      VlcPlaybackState.playing ||
      VlcPlaybackState.paused => true,
    };
  }

  /// Called from the controller listener or the timeout: both are outside a
  /// build, so a setState is owed.
  void _releaseLatch() {
    if (_pendingSeek == null && _pendingTimeout == null) return;
    if (!mounted) {
      _clearLatch();
      return;
    }
    setState(_clearLatch);
    // After the clear, so the clock picks up the engine rather than the target
    // it has just let go of.
    _publish();
  }

  void _clearLatch() {
    _pendingTimeout?.cancel();
    _pendingTimeout = null;
    _pendingSeek = null;
    _pendingFrom = null;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VlcPlayerValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        final listenable = widget.bufferedFraction;
        if (listenable == null) return _body(value, 0);
        return ValueListenableBuilder<double>(
          valueListenable: listenable,
          builder: (context, buffered, _) => _body(value, buffered),
        );
      },
    );
  }

  Widget _body(VlcPlayerValue value, double buffered) {
    final duration = value.duration;
    final hasDuration = duration > Duration.zero;
    // Live is a verdict - the app's or the engine's, which every native
    // computes as playing/paused && no length && not seekable. A length
    // that has not arrived yet is not a verdict: seekable media with an
    // unknown duration keeps its scrubber until the engine reports one.
    final isLive = widget.isLive || value.isLive;
    // Drag, track tap and D-pad steps on the bar need a scale.
    final canSeek = !isLive && value.isSeekable && hasDuration;
    if (!canSeek && _seeking) _abandonSeek();

    return PlayerScrubber(
      // The finger, then the seek the engine has not caught up with, then
      // the engine. The clock reads the same value, so it follows too -
      // wherever it is drawn. See [_shown].
      position: _shown,
      duration: duration,
      hasDuration: hasDuration,
      // libVLC reports buffering as a 0..100 percentage of the current
      // fill operation, not of the media, and it sits at 100 during steady
      // playback, so the band stays empty until there is a real figure.
      bufferRatio: buffered,
      canSeek: canSeek,
      isLive: isLive,
      skipSegments: widget.skipSegments,
      isTv: widget.isTv,
      focusNode: widget.focusNode,
      onChangeStart: (ms) {
        _beginSeek();
        setState(() => _dragTo = Duration(milliseconds: ms.round()));
        _publish();
      },
      onChanged: (ms) {
        setState(() => _dragTo = Duration(milliseconds: ms.round()));
        _publish();
      },
      onChangeEnd: (ms) {
        final target = Duration(milliseconds: ms.round());
        _commitSeek(target);
        _endSeek(target);
      },
    );
  }
}
