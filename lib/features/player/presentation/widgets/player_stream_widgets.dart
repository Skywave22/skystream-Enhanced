import 'dart:async';

import 'package:flutter/gestures.dart'
    show GestureBinding, PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../settings/presentation/player_settings_provider.dart';
import 'hotstar_player_style.dart';
import '../../../skip/data/skip_service.dart';

/// The seek bar row, driven entirely by plain values.
///
/// The elapsed/total clock used to sit above the track here. It is in the
/// transport row now, on every form factor — see [PlayerTimeLabel] — which is
/// where a viewer looks for it and which gives this widget's row back to the
/// video. The caller places it, because the buttons it sits beside are not
/// this widget's children.
///
/// Extracted so a second engine renders *the same widget* rather than a
/// lookalike. Phase 5b's "no visual diff" criterion is then satisfied by
/// construction: there is one implementation, and any future change to it
/// necessarily lands on both paths at once.
///
/// Deliberately knows nothing about the playback engine or Riverpod player
/// state.
/// The one provider it touches is [playerSettingsProvider], for the persisted
/// elapsed/remaining toggle and the D-pad seek step, which are user
/// preferences rather than engine state. It is read here rather than passed
/// down because this widget is already a [ConsumerWidget]: the seek step then
/// cannot drift from the setting by way of a caller that forgot to thread it.
/// Height of the seek bar row. The television one is taller because the bar is
/// the primary seek surface there and is read from across a room.
///
/// Sized to the track and its thumb and no more. It used to carry 14 dp of
/// dead space under an 8 dp track, which read as a gap between the scrubber
/// and the control row rather than as part of either.
const double _kBarHeight = 26;
const double _kTvBarHeight = 38;

String _formatClock(Duration duration) {
  final abs = duration.abs();
  final hours = abs.inHours;
  final minutes = abs.inMinutes.remainder(60);
  final seconds = abs.inSeconds.remainder(60);
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String _formatRemainingClock(Duration duration, Duration position) {
  final remaining = duration - position;
  return '-${_formatClock(remaining.isNegative ? Duration.zero : remaining)}';
}

class PlayerScrubber extends ConsumerWidget {
  const PlayerScrubber({
    super.key,
    required this.position,
    required this.duration,
    required this.bufferRatio,
    required this.canSeek,
    this.hasDuration = true,
    this.isLive = false,
    this.skipSegments = const <SkipSegment>[],
    this.isTv = false,
    this.focusNode,
    this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
  });

  /// What the label and thumb should show — the drag position while scrubbing,
  /// the playback position otherwise.
  final Duration position;
  final Duration duration;

  /// Whether [duration] is known. False while the engine has not reported a
  /// length yet: the clock shows `--:--` for the total and the track stays at
  /// 0% rather than clamping the position onto a 1 ms scale and painting the
  /// whole bar. Not the same as [isLive], which is a verdict about the media.
  final bool hasDuration;

  /// 0..1 of [duration] currently buffered.
  final double bufferRatio;

  final bool canSeek;
  final bool isLive;
  final List<SkipSegment> skipSegments;

  /// Ten-foot sizing: a fatter bar, a fatter track and a thumb that can be
  /// seen from a sofa.
  final bool isTv;

  final FocusNode? focusNode;

  /// Milliseconds, matching [PlayerSeekBar]'s value space.
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final durationMs = duration.inMilliseconds.toDouble();
    final maxValue = hasDuration ? durationMs : 1.0;
    // The same step every other seek path uses. Zero or negative is not a
    // step, so it falls back the way the controls' own `_seekStep` does.
    final seekSeconds =
        ref.watch(
          playerSettingsProvider.select((s) => s.asData?.value.seekDuration),
        ) ??
        10;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: isTv ? _kTvBarHeight : _kBarHeight,
          child: PlayerSeekBar(
            value: hasDuration
                ? position.inMilliseconds.toDouble().clamp(0, maxValue)
                : 0.0,
            min: 0.0,
            max: maxValue,
            // D-pad Left/Right jumps the viewer's configured seek duration.
            step: (seekSeconds > 0 ? seekSeconds : 10) * 1000.0,
            focusNode: focusNode,
            isTv: isTv,
            canSeek: canSeek,
            bufferRatio: bufferRatio,
            skipSegments: skipSegments,
            onChanged: canSeek ? onChanged : null,
            onChangeStart: canSeek ? onChangeStart : null,
            onChangeEnd: canSeek ? onChangeEnd : null,
          ),
        ),
      ],
    );
  }
}

/// The elapsed/total clock — `12:04 / 48:31` — or the LIVE badge that stands in
/// for it on a feed with no end to count towards.
///
/// Its own widget because it has two homes. Above the track on touch and on a
/// television, where the bar is the thing being read; and beside the transport
/// buttons on desktop, where the layout follows the convention every desktop
/// player in the world uses. One implementation, so the tap that swaps elapsed
/// for remaining, the tabular figures and the live case cannot drift apart
/// between the two placements.
///
/// Driven by plain values, like everything else in this file: what it does
/// *not* know is which position is the truth at this instant — the finger's,
/// a seek the engine has not honoured yet, or the engine's. That is the seek
/// bar's judgement, and the caller passes the answer in.
class PlayerTimeLabel extends ConsumerWidget {
  const PlayerTimeLabel({
    required this.position,
    required this.duration,
    this.hasDuration = true,
    this.isLive = false,
    super.key,
  });

  final Duration position;
  final Duration duration;

  /// Whether [duration] is known. The total reads `--:--` until it is, rather
  /// than `0:00`, which would say the media has no length.
  final bool hasDuration;

  final bool isLive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (isLive) return const _LivePill();

    final showRemaining =
        ref.watch(
          playerSettingsProvider.select(
            (s) => s.asData?.value.showRemainingTime,
          ),
        ) ??
        false;
    final total = hasDuration ? _formatClock(duration) : '--:--';
    final label = showRemaining && hasDuration
        ? '${_formatRemainingClock(duration, position)} / $total'
        : '${_formatClock(position)} / $total';

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => ref
            .read(playerSettingsProvider.notifier)
            .setShowRemainingTime(!showRemaining),
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
          style: const TextStyle(
            color: HotstarPlayerStyle.primaryText,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            // So the clock does not jitter as the digits tick over.
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

/// The red LIVE badge shown instead of the clock on a live stream.
///
/// No padding and no [Align] of its own: it stands exactly where the clock it
/// replaces stands, and the transport row places both.
class _LivePill extends StatelessWidget {
  const _LivePill();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        // The token, not `Colors.red`. They are three points apart and the
        // token is the one with the contrast behind it; this pill was the only
        // thing in the player still reaching past it for the Material swatch.
        color: HotstarPlayerStyle.liveRed.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: HotstarPlayerStyle.liveRed.withValues(alpha: 0.45),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.circle, color: HotstarPlayerStyle.liveRed, size: 7),
          const SizedBox(width: 5),
          Text(
            AppLocalizations.of(context)!.live,
            style: const TextStyle(
              color: HotstarPlayerStyle.liveRed,
              fontWeight: FontWeight.w800,
              fontSize: 11,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// The single shared player spinner — used by the centered buffering indicator
/// and by the play/pause button so they look identical (they both appear in the
/// screen centre on touch).
class _PlayerSpinner extends StatelessWidget {
  const _PlayerSpinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 42,
      height: 42,
      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3.5),
    );
  }
}

/// The centred buffering spinner.
///
/// Deliberately has no opinion about when it should appear: it used to read
/// three fields off the old player controller to decide, which meant the
/// decision lived in the wrong place and could disagree with the overlay
/// around it. The caller owns visibility now.
class PlayerBufferingIndicator extends StatelessWidget {
  const PlayerBufferingIndicator({super.key});

  @override
  Widget build(BuildContext context) =>
      const IgnorePointer(child: Center(child: _PlayerSpinner()));
}

class _TrackInterval {
  final double start;
  final double end;
  final bool isSkipSegment;

  _TrackInterval({
    required this.start,
    required this.end,
    required this.isSkipSegment,
  });
}

class PlayerSeekBar extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final double step;
  final FocusNode? focusNode;

  /// Ten-foot sizing - see [PlayerScrubber.isTv].
  final bool isTv;
  final bool canSeek;
  final double bufferRatio;
  final List<SkipSegment> skipSegments;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;

  const PlayerSeekBar({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    this.focusNode,
    this.isTv = false,
    required this.canSeek,
    required this.bufferRatio,
    required this.skipSegments,
    this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
  });

  @override
  State<PlayerSeekBar> createState() => _PlayerSeekBarState();
}

class _PlayerSeekBarState extends State<PlayerSeekBar> {
  late final FocusNode _focusNode;
  bool _isFocused = false;
  bool _isDragging = false;
  Timer? _seekCommitTimer;
  late final VoidCallback _focusListener;

  bool _isTrackHovered = false;
  double? _lastDragValue;

  /// Pointer x is kept out of State so that mouse motion, which arrives every
  /// frame, repaints just the hover line and tooltip rather than rebuilding the
  /// whole scrubber and dirtying the chrome layer it sits in. Only the coarse
  /// facts (hovered at all, which track interval is under the pointer) go
  /// through setState, and those change at most a few times per pass.
  final ValueNotifier<double> _hoverX = ValueNotifier<double>(0.0);

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode(debugLabel: 'player-seek-bar');
    _focusListener = () {
      if (mounted) setState(() => _isFocused = _focusNode.hasFocus);
    };
    _focusNode.addListener(_focusListener);
  }

  @override
  void dispose() {
    _seekCommitTimer?.cancel();
    _hoverX.dispose();
    _focusNode.removeListener(_focusListener);
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  void _handleDpadSeek(double newValue) {
    if (!_isDragging) {
      setState(() {
        _isDragging = true;
      });
      widget.onChangeStart?.call(newValue);
    }
    widget.onChanged?.call(newValue);

    _seekCommitTimer?.cancel();
    _seekCommitTimer = Timer(const Duration(milliseconds: 500), () {
      widget.onChangeEnd?.call(newValue);
      setState(() {
        _isDragging = false;
      });
    });
  }

  /// The value one D-pad step of [delta] away, clamped to the track - or null
  /// when the thumb is already at that end and the press would do nothing.
  double? _stepped(double delta) {
    final next = (widget.value + delta).clamp(widget.min, widget.max);
    return next == widget.value ? null : next;
  }

  double _getValueFromOffset(double localX, double trackWidth) {
    if (trackWidth <= 0) return widget.min;
    final ratio = (localX / trackWidth).clamp(0.0, 1.0);
    return widget.min + ratio * (widget.max - widget.min);
  }

  int _intervalIndexAt(double x, List<_TrackInterval> intervals) {
    return intervals.indexWhere((i) => x >= i.start && x <= i.end);
  }

  /// A rebuild is only owed when the pointer crosses into a different track
  /// interval, because that resizes the segments; within one interval the
  /// notifier alone carries the movement.
  void _moveHover(double x, List<_TrackInterval> intervals) {
    final previous = _hoverX.value;
    _hoverX.value = x;
    if (_intervalIndexAt(previous, intervals) !=
        _intervalIndexAt(x, intervals)) {
      setState(() {});
    }
  }

  /// One wheel notch over the bar: a step in the direction it was spun.
  ///
  /// The step is the viewer's configured seek duration, the same one the D-pad
  /// takes, so a wheel and an arrow move the same distance.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
      if (resolved is! PointerScrollEvent || !widget.canSeek) return;
      final Offset delta = resolved.scrollDelta;
      final bool horizontal = delta.dx.abs() > delta.dy.abs();
      final double primary = horizontal ? delta.dx : delta.dy;
      if (primary == 0) return;
      // Up and right are both forward, matching the overlay's own wheel.
      final next = _stepped(
        (horizontal ? primary > 0 : primary < 0) ? widget.step : -widget.step,
      );
      if (next == null) return;
      _handleDpadSeek(next);
    });
  }

  String _formatDuration(double ms) {
    if (ms.isNaN || ms.isInfinite) return '0:00';
    final duration = Duration(milliseconds: ms.toInt());
    final int hours = duration.inHours;
    final int minutes = duration.inMinutes.remainder(60);
    final int seconds = duration.inSeconds.remainder(60);

    final String secondsStr = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      final String minutesStr = minutes.toString().padLeft(2, '0');
      return '$hours:$minutesStr:$secondsStr';
    } else {
      return '$minutes:$secondsStr';
    }
  }

  @override
  Widget build(BuildContext context) {
    final increased = _stepped(widget.step);
    final decreased = _stepped(-widget.step);
    final Widget bar = Focus(
      focusNode: _focusNode,
      canRequestFocus: widget.canSeek,
      skipTraversal: !widget.canSeek,
      onKeyEvent: (node, event) {
        if (!widget.canSeek) return KeyEventResult.ignored;
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }

        final logicalKey = event.logicalKey;

        // Left/Right step the position - but only while there is a step left
        // to take. A press that clamps to where the thumb already is has done
        // nothing, and claiming it stops the key reaching the overlay above,
        // whose handler is what keeps the chrome on screen: at the end of a
        // track the bars would then time out under a viewer still pressing.
        if (logicalKey == LogicalKeyboardKey.arrowLeft ||
            logicalKey == LogicalKeyboardKey.arrowRight) {
          // The same helper the screen reader's increase/decrease actions
          // use, so a key and a gesture can never mean different distances.
          final next = _stepped(
            logicalKey == LogicalKeyboardKey.arrowLeft
                ? -widget.step
                : widget.step,
          );
          if (next == null) return KeyEventResult.ignored;
          _handleDpadSeek(next);
          return KeyEventResult.handled;
        }

        // Up and Down are traversal, and deliberately not answered here.
        //
        // This used to move focus by hand (`focusInDirection`, falling back to
        // previousFocus/nextFocus) and report the key handled either way. Key
        // dispatch runs the focused node first and stops at the first widget
        // that claims the event, so every arrow off the bar was swallowed
        // before the player's key sink could see it - and that sink is what
        // restarts the chrome's hide clock. The bars could vanish one press
        // into navigating away from the scrubber. Returning ignored lets
        // DirectionalFocusAction perform exactly the same move (the bar sits
        // in the chrome's traversal group) while the key still bubbles.
        return KeyEventResult.ignored;
      },
      // No focus ring. The bar already says it has the remote in the one place
      // a viewer is looking: the thumb swells from 10 dp to 14, or to 20 on a
      // television - see the thumb block below. A rounded rule around the
      // whole width on top of that was a second, larger answer to a question
      // the first one had already answered, and on a ten-foot bar it drew a
      // 1200 dp box around a 20 dp cursor.
      //
      // The optical insets live in [HotstarPlayerStyle] because the floating
      // overlays answer to the same two lines; see `trackInset`. They are the
      // whole inset now that no border is taking part of it, so the track does
      // not move by the ring's width when focus arrives or leaves.
      // The inset either side of the track is *paint*, not target: a press in
      // that band still belongs to the bar rather than falling through to the
      // video behind it.
      //
      // The focus ring used to provide this by accident - RenderDecoratedBox
      // hit-tests itself, so the ring's box caught the padding band - and
      // taking the ring away took the bar's outer 16 dp with it.
      // next_episode_countdown_test caught it: a finger at the end of the bar
      // reached the page behind it instead.
      // An empty [BoxDecoration] paints nothing and hit-tests everything:
      // `BoxDecoration.hitTest` answers for any point inside a rectangular
      // shape, whatever it was given to draw. That is the whole reason it is
      // here rather than a bare [Padding].
      child: DecoratedBox(
        decoration: const BoxDecoration(),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            HotstarPlayerStyle.trackInset,
            2,
            HotstarPlayerStyle.trackEndInset,
            2,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final trackWidth = constraints.maxWidth;
              final double ratio = (widget.max > widget.min)
                  ? (widget.value - widget.min) / (widget.max - widget.min)
                  : 0.0;
              final double progressWidth = (ratio * trackWidth).clamp(
                0.0,
                trackWidth,
              );

              // Calculate track intervals based on skip segments
              final List<_TrackInterval> intervals = [];
              if (widget.max <= widget.min || widget.skipSegments.isEmpty) {
                intervals.add(
                  _TrackInterval(
                    start: 0.0,
                    end: trackWidth,
                    isSkipSegment: false,
                  ),
                );
              } else {
                final List<_TrackInterval> rawIntervals = [];
                for (final seg in widget.skipSegments) {
                  final double startMs = seg.startTime * 1000.0;
                  final double endMs = seg.endTime * 1000.0;
                  final double startRatio =
                      (startMs / (widget.max - widget.min)).clamp(0.0, 1.0);
                  final double endRatio = (endMs / (widget.max - widget.min))
                      .clamp(0.0, 1.0);
                  if (startRatio < endRatio) {
                    rawIntervals.add(
                      _TrackInterval(
                        start: startRatio * trackWidth,
                        end: endRatio * trackWidth,
                        isSkipSegment: true,
                      ),
                    );
                  }
                }

                rawIntervals.sort((a, b) => a.start.compareTo(b.start));

                double currentX = 0.0;
                for (final seg in rawIntervals) {
                  if (seg.start > currentX) {
                    intervals.add(
                      _TrackInterval(
                        start: currentX,
                        end: seg.start,
                        isSkipSegment: false,
                      ),
                    );
                  }
                  final double segStart = seg.start.clamp(currentX, trackWidth);
                  final double segEnd = seg.end.clamp(segStart, trackWidth);
                  if (segStart < segEnd) {
                    intervals.add(
                      _TrackInterval(
                        start: segStart,
                        end: segEnd,
                        isSkipSegment: true,
                      ),
                    );
                    currentX = segEnd;
                  }
                }
                if (currentX < trackWidth) {
                  intervals.add(
                    _TrackInterval(
                      start: currentX,
                      end: trackWidth,
                      isSkipSegment: false,
                    ),
                  );
                }
              }

              // Adjust intervals to introduce a 2px visual gap (seam)
              final List<_TrackInterval> visualIntervals = [];
              for (final interval in intervals) {
                double start = interval.start;
                double end = interval.end;
                if (start > 0.0) {
                  start += 1.0;
                }
                if (end < trackWidth) {
                  end -= 1.0;
                }
                if (start < end) {
                  visualIntervals.add(
                    _TrackInterval(
                      start: start,
                      end: end,
                      isSkipSegment: interval.isSkipSegment,
                    ),
                  );
                }
              }

              // Precompute heights for each interval depending on hover position
              final int hoveredIntervalIndex = _intervalIndexAt(
                _hoverX.value,
                visualIntervals,
              );
              final double trackHeight = widget.isTv ? 10.0 : 8.0;
              final List<double> intervalHeights = [];
              for (int i = 0; i < visualIntervals.length; i++) {
                final bool isIntervalHovered =
                    (_isTrackHovered || _isDragging) &&
                    i == hoveredIntervalIndex;
                intervalHeights.add(
                  isIntervalHovered ? trackHeight + 4.0 : trackHeight,
                );
              }

              // Thumb morphs if hovering anywhere on track or actively dragging
              final bool isMorphed = _isDragging || _isTrackHovered;

              final double thumbWidth;
              final double thumbHeight;
              final double thumbRadius;
              final double thumbOpacity;

              if (isMorphed) {
                thumbWidth = 3.0;
                thumbHeight = 18.0;
                thumbRadius = 2.0; // rounded-sm ≈ 2px
                thumbOpacity = 1.0;
              } else if (_isFocused) {
                // The focused thumb is the D-pad's cursor, so it is the one
                // state that has to read from across a room.
                thumbWidth = widget.isTv ? 20.0 : 14.0;
                thumbHeight = widget.isTv ? 20.0 : 14.0;
                thumbRadius = thumbWidth / 2;
                thumbOpacity = 1.0;
              } else {
                thumbWidth = 10.0;
                thumbHeight = 10.0;
                thumbRadius = 5.0;
                thumbOpacity = 0.9;
              }

              return Listener(
                // A wheel over the bar seeks, which is what it does over a
                // timeline in every desktop player. Through the resolver so the
                // innermost widget wins: without it the overlay's own handler
                // would take the same notch and change the volume instead.
                //
                // Routed into [_handleDpadSeek], so a spin coalesces the way a
                // held D-pad does - one seek at the end of the burst rather than
                // one per notch, which would leave the engine chasing a value
                // the wheel had already moved past.
                onPointerSignal: widget.canSeek ? _onPointerSignal : null,
                child: MouseRegion(
                  onEnter: (_) {
                    if (widget.canSeek) {
                      setState(() => _isTrackHovered = true);
                    }
                  },
                  onExit: (_) {
                    _hoverX.value = 0.0;
                    setState(() => _isTrackHovered = false);
                  },
                  onHover: (event) {
                    if (widget.canSeek) {
                      _moveHover(event.localPosition.dx, visualIntervals);
                    }
                  },
                  cursor: widget.canSeek
                      ? SystemMouseCursors.click
                      : SystemMouseCursors.basic,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: widget.canSeek
                        ? (details) {
                            _hoverX.value = details.localPosition.dx;
                            setState(() => _isDragging = true);
                            final val = _getValueFromOffset(
                              details.localPosition.dx,
                              trackWidth,
                            );
                            _lastDragValue = val;
                            widget.onChangeStart?.call(val);
                          }
                        : null,
                    onHorizontalDragUpdate: widget.canSeek
                        ? (details) {
                            _moveHover(
                              details.localPosition.dx,
                              visualIntervals,
                            );
                            final val = _getValueFromOffset(
                              details.localPosition.dx,
                              trackWidth,
                            );
                            _lastDragValue = val;
                            widget.onChanged?.call(val);
                          }
                        : null,
                    onHorizontalDragEnd: widget.canSeek
                        ? (details) {
                            setState(() {
                              _isDragging = false;
                            });
                            widget.onChangeEnd?.call(
                              _lastDragValue ?? widget.value,
                            );
                          }
                        : null,
                    onTapDown: widget.canSeek
                        ? (details) {
                            final val = _getValueFromOffset(
                              details.localPosition.dx,
                              trackWidth,
                            );
                            widget.onChangeStart?.call(val);
                            widget.onChanged?.call(val);
                            widget.onChangeEnd?.call(val);
                          }
                        : null,
                    child: Container(
                      height: widget.isTv ? _kTvBarHeight : _kBarHeight,
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 12.0),
                      child: Stack(
                        alignment: Alignment.centerLeft,
                        clipBehavior: Clip.none,
                        children: [
                          // 1. Track Background segments
                          for (int i = 0; i < visualIntervals.length; i++)
                            Positioned(
                              left: visualIntervals[i].start,
                              width:
                                  visualIntervals[i].end -
                                  visualIntervals[i].start,
                              child: Align(
                                alignment: Alignment.center,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 150),
                                  curve: const Cubic(0.4, 0.0, 0.2, 1.0),
                                  height: intervalHeights[i],
                                  width: double.infinity,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(4.0),
                                    color: visualIntervals[i].isSkipSegment
                                        ? HotstarPlayerStyle.skipSegment
                                              .withValues(alpha: 0.35)
                                        : const Color(
                                            0x4DCFDEF6,
                                          ), // rgba(207, 222, 246, 0.30)
                                  ),
                                ),
                              ),
                            ),

                          // 2. Buffer progress segments
                          if (widget.bufferRatio > 0.0)
                            for (int i = 0; i < visualIntervals.length; i++)
                              _buildIntervalBuffer(
                                visualIntervals[i],
                                trackWidth,
                                intervalHeights[i],
                              ),

                          // 3. Played progress segments
                          for (int i = 0; i < visualIntervals.length; i++)
                            _buildIntervalProgress(
                              visualIntervals[i],
                              progressWidth,
                              intervalHeights[i],
                            ),

                          // 3.5 Hover Vertical Line (only when hovered and not dragging).
                          // Moved by a paint-only translate inside its own boundary
                          // rather than by re-positioning within the Stack, which
                          // would relayout and repaint the whole track every frame.
                          if (_isTrackHovered && !_isDragging)
                            Positioned(
                              left: 0.0,
                              child: RepaintBoundary(
                                child: ValueListenableBuilder<double>(
                                  valueListenable: _hoverX,
                                  builder: (context, hoverX, child) {
                                    return Transform.translate(
                                      offset: Offset(hoverX, 0.0),
                                      child: child,
                                    );
                                  },
                                  child: FractionalTranslation(
                                    translation: const Offset(-0.5, 0.0),
                                    child: Align(
                                      alignment: Alignment.center,
                                      child: Container(
                                        width: 1.5,
                                        height: hoveredIntervalIndex != -1
                                            ? intervalHeights[hoveredIntervalIndex]
                                            : trackHeight,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),

                          // 3.6 Hover/Drag Timestamp Tooltip (visible on hover and during active drag)
                          if (_isTrackHovered || _isDragging)
                            Positioned(
                              left: 0.0,
                              top: -38.0, // Float higher above the seek bar
                              child: RepaintBoundary(
                                child: ValueListenableBuilder<double>(
                                  valueListenable: _hoverX,
                                  builder: (context, hoverX, _) {
                                    final double tooltipPositionX =
                                        (_isDragging && hoverX == 0.0)
                                        ? progressWidth
                                        : hoverX;

                                    return Transform.translate(
                                      offset: Offset(
                                        tooltipPositionX.clamp(
                                          20.0,
                                          trackWidth - 20.0,
                                        ),
                                        0.0,
                                      ),
                                      child: FractionalTranslation(
                                        translation: const Offset(-0.5, 0.0),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10.0,
                                            vertical: 5.0,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(0xE61A1A1A), // rgba(26, 26, 26, 0.9) - dark grey
                                            borderRadius: BorderRadius.circular(
                                              16.0,
                                            ), // Pill shape
                                            border: Border.all(
                                              color: Colors.white.withValues(
                                                alpha: 0.15,
                                              ),
                                              width: 0.5,
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.black.withValues(
                                                  alpha: 0.25,
                                                ),
                                                blurRadius: 4.0,
                                                offset: const Offset(0.0, 2.0),
                                              ),
                                            ],
                                          ),
                                          child: Text(
                                            _formatDuration(
                                              _getValueFromOffset(
                                                tooltipPositionX,
                                                trackWidth,
                                              ),
                                            ),
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 11.0,
                                              fontWeight: FontWeight.w700,
                                              fontFeatures: [
                                                FontFeature.tabularFigures(),
                                              ], // Tabular/monospace figures
                                              height: 1.0,
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),

                          // 4. Scrubber Thumb (centered horizontally at progressWidth)
                          if (widget.canSeek)
                            Positioned(
                              left: progressWidth,
                              child: FractionalTranslation(
                                translation: const Offset(-0.5, 0.0),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 150),
                                  curve: const Cubic(0.4, 0.0, 0.2, 1.0),
                                  width: thumbWidth,
                                  height: thumbHeight,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(
                                      alpha: thumbOpacity,
                                    ),
                                    borderRadius: BorderRadius.circular(
                                      thumbRadius,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    // A slider with a position and two step actions: without this the bar is
    // invisible to a screen reader, which is the difference between a seekable
    // player and an unusable one. No label yet - naming it needs a translated
    // string, and the value and the actions are what make it operable.
    return Semantics(
      slider: true,
      value: _formatDuration(widget.value),
      increasedValue: _formatDuration(increased ?? widget.value),
      decreasedValue: _formatDuration(decreased ?? widget.value),
      onIncrease: widget.canSeek && increased != null
          ? () => _handleDpadSeek(increased)
          : null,
      onDecrease: widget.canSeek && decreased != null
          ? () => _handleDpadSeek(decreased)
          : null,
      child: bar,
    );
  }

  Widget _buildIntervalBuffer(
    _TrackInterval interval,
    double trackWidth,
    double height,
  ) {
    final double bufferX = widget.bufferRatio * trackWidth;
    final double intervalBufferWidth = (bufferX - interval.start).clamp(
      0.0,
      interval.end - interval.start,
    );
    if (intervalBufferWidth <= 0.0) return const SizedBox.shrink();
    return Positioned(
      left: interval.start,
      width: intervalBufferWidth,
      child: Align(
        alignment: Alignment.center,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: const Cubic(0.4, 0.0, 0.2, 1.0),
          height: height,
          width: double.infinity,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4.0),
            child: Container(color: Colors.white.withValues(alpha: 0.25)),
          ),
        ),
      ),
    );
  }

  Widget _buildIntervalProgress(
    _TrackInterval interval,
    double progressWidth,
    double height,
  ) {
    final double intervalProgressWidth = (progressWidth - interval.start).clamp(
      0.0,
      interval.end - interval.start,
    );
    if (intervalProgressWidth <= 0.0) return const SizedBox.shrink();
    return Positioned(
      left: interval.start,
      width: intervalProgressWidth,
      child: Align(
        alignment: Alignment.center,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: const Cubic(0.4, 0.0, 0.2, 1.0),
          height: height,
          width: double.infinity,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4.0),
            child: Container(
              color: interval.isSkipSegment
                  ? HotstarPlayerStyle.skipSegment
                  : Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
