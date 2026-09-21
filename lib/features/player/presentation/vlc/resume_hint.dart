import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../widgets/hotstar_player_style.dart';
import '../widgets/player_activation.dart';

/// A brief "you are being resumed from here — start over?" affordance.
///
/// Deliberately **not** the old resume_prompt_overlay. That one blocked the
/// start of playback behind an 8 s countdown whose timeout was *start over*
/// (resume_prompt_overlay.dart:47-55), so looking away from the screen threw
/// away the viewer's position. The current player resumes silently, which is
/// the right default; the only thing genuinely missing is a way to notice that
/// it happened and undo it. So this appears alongside playback, never gates
/// it, and expires on its own.
///
/// Engine-agnostic and owns no player state, like its neighbours in this
/// directory: the position to show and both outcomes come from the caller.
///
/// Callbacks: [onStartOver] fires at most once, when the viewer asks for it.
/// [onDismissed] fires once the hint has finished animating out — by timeout,
/// by the dismiss button, by Back/Escape, or after [onStartOver] — and means
/// "unmount me". A parent that already drops the hint inside [onStartOver]
/// simply never sees it.
class ResumeHint extends StatefulWidget {
  const ResumeHint({
    required this.position,
    required this.onStartOver,
    required this.onDismissed,
    this.visibleFor = const Duration(seconds: 6),
    this.isTv = false,
    super.key,
  });

  /// Where playback was resumed from, for display only. The seek already
  /// happened — this widget never asks for one.
  final Duration position;

  /// How long the hint stays up when nobody touches it. Long enough to read a
  /// timestamp and decide, short enough not to sit over the picture.
  final Duration visibleFor;

  final bool isTv;

  /// Restart from the beginning. One action, one press — the whole point of
  /// the hint.
  final VoidCallback onStartOver;

  /// The hint is done and should be removed from the tree.
  final VoidCallback onDismissed;

  @override
  State<ResumeHint> createState() => _ResumeHintState();
}

class _ResumeHintState extends State<ResumeHint>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade;
  Timer? _hold;

  /// Latches on the first outcome. Without it the expiry timer can fire into
  /// a hint the viewer just acted on and re-enter the exit animation.
  bool _settled = false;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(
      vsync: this,
      duration: HotstarPlayerStyle.controlFadeDuration,
    )..addStatusListener(_onFadeStatus);
    _fade.forward();
    _restartHold();
  }

  @override
  void dispose() {
    _hold?.cancel();
    _fade.dispose();
    super.dispose();
  }

  void _onFadeStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed) widget.onDismissed();
  }

  void _restartHold() {
    _hold?.cancel();
    _hold = Timer(widget.visibleFor, _hide);
  }

  void _hide() {
    if (_settled) return;
    _settled = true;
    _hold?.cancel();
    _fade.reverse();
  }

  void _startOver() {
    if (_settled) return;
    widget.onStartOver();
    _hide();
  }

  /// The expiry clock stops while the remote is on the hint and restarts when
  /// it leaves.
  ///
  /// Not a nicety: on TV, vanishing out from under the focused node drops
  /// focus into nothing and the next D-pad press goes nowhere. A control that
  /// can be focused must not disappear while it is focused.
  void _onFocusChange(bool hasFocus) {
    if (_settled) return;
    hasFocus ? _hold?.cancel() : _restartHold();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      _hide();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final padding = MediaQuery.viewPaddingOf(context);
    final edge = widget.isTv
        ? HotstarPlayerStyle.tvEdgeInset
        : HotstarPlayerStyle.edgeInset;

    return Align(
      alignment: Alignment.bottomLeft,
      child: Padding(
        padding: EdgeInsets.only(
          // The bar's own left padding plus the optical inset the track and
          // the first control are both held by: a hint flush to the chrome's
          // padding sits a clear 16 dp outside the column everything else in
          // the player lines up on. See `HotstarPlayerStyle.trackInset`.
          left:
              (widget.isTv
                  ? edge
                  : (padding.left > edge ? padding.left : edge)) +
              HotstarPlayerStyle.trackInset,
          // Anchored off the same chrome token the bottom bar is sized by, so
          // the hint clears the scrubber instead of guessing at it. Left of
          // the next-episode card, which anchors bottom-right — the two are
          // never up together, but neither is ever in the other's way.
          //
          // One number for every form factor. There used to be a second,
          // `compact ? 60.0`, taken whenever the shortest side was under
          // 600 dp - which is a phone in landscape, a small desktop window and
          // every 960x540 television. The bar is 102 to 137 dp tall, so on all
          // three the hint was anchored inside it and came up over the
          // scrubber and the transport buttons.
          bottom:
              HotstarPlayerStyle.bottomChromeHeightFor(isTv: widget.isTv) +
              12 +
              padding.bottom,
        ),
        child: FadeTransition(
          opacity: _fade,
          child: SlideTransition(
            position:
                Tween<Offset>(
                  begin: const Offset(0, 0.35),
                  end: Offset.zero,
                ).animate(
                  CurvedAnimation(parent: _fade, curve: Curves.easeOutCubic),
                ),
            child: FocusTraversalGroup(
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onKeyEvent: _onKey,
                onFocusChange: _onFocusChange,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _StartOverPill(
                      label: l10n.startOver,
                      // "Paused at 42:15" — the stored position, which is what
                      // playback was just moved to.
                      detail: l10n.pausedAt(_clock(widget.position)),
                      isTv: widget.isTv,
                      onPressed: _startOver,
                    ),
                    const SizedBox(width: 8),
                    _DismissButton(
                      tooltip: l10n.dismiss,
                      isTv: widget.isTv,
                      onPressed: _hide,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Focus node labels, so the integration and the tests can assert where the
/// remote is without anyone owning a [FocusNode]. The hint creates none;
/// traversal between the two controls is entirely native.
const String kStartOverFocusLabel = 'resume_hint_start_over';
const String kResumeDismissFocusLabel = 'resume_hint_dismiss';

/// `mm:ss`, growing to `h:mm:ss` only when there are hours to show — a movie
/// resumed at 42:15 should not read `00:42:15`.
String _clock(Duration position) {
  final minutes = position.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = position.inSeconds.remainder(60).toString().padLeft(2, '0');
  final hours = position.inHours;
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

class _StartOverPill extends StatefulWidget {
  const _StartOverPill({
    required this.label,
    required this.detail,
    required this.onPressed,
    required this.isTv,
  });

  final String label;
  final String detail;
  final VoidCallback onPressed;
  final bool isTv;

  @override
  State<_StartOverPill> createState() => _StartOverPillState();
}

class _StartOverPillState extends State<_StartOverPill> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${widget.label}. ${widget.detail}',
      child: Focus(
        debugLabel: kStartOverFocusLabel,
        onKeyEvent: (node, event) => _activateOnSelect(event, widget.onPressed),
        onFocusChange: (value) => setState(() => _focused = value),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(24),
          child: InkWell(
            onTap: widget.onPressed,
            // See _CardButton in next_episode_countdown.dart: a focusable
            // InkWell would put a second, key-deaf node under the wrapper.
            canRequestFocus: false,
            borderRadius: BorderRadius.circular(24),
            child: AnimatedContainer(
              duration: HotstarPlayerStyle.fastMotionDuration,
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.fromLTRB(14, 8, 18, 8),
              decoration: _pillDecoration(
                focused: _focused,
                isTv: widget.isTv,
                radius: 24,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.replay_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        widget.detail,
                        style: const TextStyle(
                          color: HotstarPlayerStyle.secondaryText,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DismissButton extends StatefulWidget {
  const _DismissButton({
    required this.tooltip,
    required this.onPressed,
    required this.isTv,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final bool isTv;

  @override
  State<_DismissButton> createState() => _DismissButtonState();
}

class _DismissButtonState extends State<_DismissButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        label: widget.tooltip,
        child: Focus(
          debugLabel: kResumeDismissFocusLabel,
          onKeyEvent: (node, event) =>
              _activateOnSelect(event, widget.onPressed),
          onFocusChange: (value) => setState(() => _focused = value),
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            child: InkWell(
              onTap: widget.onPressed,
              canRequestFocus: false,
              customBorder: const CircleBorder(),
              child: AnimatedContainer(
                duration: HotstarPlayerStyle.fastMotionDuration,
                width: 44,
                height: 44,
                decoration: _pillDecoration(
                  focused: _focused,
                  isTv: widget.isTv,
                  radius: 22,
                ),
                child: const Icon(
                  Icons.close_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared skin for the hint's two controls, so the pill and the dismiss button
/// read as one object rather than two widgets that happen to be adjacent.
BoxDecoration _pillDecoration({
  required bool focused,
  required bool isTv,
  required double radius,
}) {
  final ring = focused && isTv;
  return BoxDecoration(
    color: focused
        ? HotstarPlayerStyle.accent.withValues(alpha: 0.24)
        : Colors.black.withValues(alpha: 0.62),
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(
      color: ring ? HotstarPlayerStyle.accent : HotstarPlayerStyle.divider,
      width: ring ? 2 : 1,
    ),
    boxShadow: ring
        ? [
            BoxShadow(
              color: HotstarPlayerStyle.accent.withValues(alpha: 0.3),
              blurRadius: 10,
            ),
          ]
        : null,
  );
}

/// D-pad select and its keyboard and controller equivalents, from the shared
/// [isPlayerActivation] predicate. Directional movement is left to native
/// traversal — nothing here moves focus.
KeyEventResult _activateOnSelect(KeyEvent event, VoidCallback onPressed) {
  if (event is! KeyDownEvent) return KeyEventResult.ignored;
  if (isPlayerActivation(event.logicalKey)) {
    onPressed();
    return KeyEventResult.handled;
  }
  return KeyEventResult.ignored;
}
