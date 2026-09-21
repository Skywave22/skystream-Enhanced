import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../widgets/hotstar_player_style.dart';
import '../widgets/player_activation.dart';
import '../../../../shared/focus/app_focus.dart';

/// What the media stopping means, once the screen has consulted the episode
/// list.
enum EndedKind {
  /// Nothing follows at all: a film, or the last episode of a series.
  finished,

  /// An episode follows, but the viewer pressed Cancel on the up-next card.
  ///
  /// The refusal is honoured: playback does not auto-advance, so this card
  /// carries Next as its primary action instead.
  declinedNext,
}

/// The key the screen hangs on the card.
const Key endedCardKey = Key('player-ended-card');

/// Focus node labels, in [kPlayNextFocusLabel]'s convention. Public so a test
/// can locate the remote without the card owning a [FocusNode] of its own;
/// traversal between the actions stays native.
const String kEndedNextFocusLabel = 'ended_next_episode';
const String kEndedStartOverFocusLabel = 'ended_start_over';
const String kEndedCloseFocusLabel = 'ended_close';

/// What a film — or the last episode of a series — ends on, instead of a dead
/// frame.
///
/// Engine-agnostic and stateless about playback, like [NextEpisodeCountdown]:
/// every value it renders and every outcome is handed in, so this file imports
/// nothing from the player package.
///
/// Rendering is a paint, not a layer: a [ColoredBox] rather than an
/// [AnimatedOpacity] or a [BackdropFilter]. A full-bleed effect layer over a
/// platform view is re-surfaced on every show and hide, which
/// controls_layer_shape_test's 40 %-of-viewport rule forbids.
class EndedCard extends StatefulWidget {
  const EndedCard({
    required this.title,
    required this.kind,
    required this.onStartOver,
    required this.onClose,
    this.onNextEpisode,
    this.nextLabel,
    this.isTv = false,
    super.key,
  }) : assert(
         (kind == EndedKind.declinedNext) == (onNextEpisode != null),
         'declinedNext is the only kind with a next episode to offer, and it '
         'always has one',
       );

  /// What the headline says has finished: the film or series title for
  /// [EndedKind.finished], the episode's own name for a declined advance.
  final String title;

  final EndedKind kind;

  final VoidCallback onStartOver;

  /// Leaves the player.
  final VoidCallback onClose;

  /// Plays the episode the viewer declined during the credits. Null unless
  /// [kind] is [EndedKind.declinedNext].
  final VoidCallback? onNextEpisode;

  /// The next action's label, already localised and already decorated with
  /// `S2 E5` where the numbers are known. Null falls back to
  /// [AppLocalizations.next].
  final String? nextLabel;

  final bool isTv;

  @override
  State<EndedCard> createState() => _EndedCardState();
}

class _EndedCardState extends State<EndedCard> {
  /// The card's own focus scope, and the reason the remote can reach it.
  ///
  /// Flutter applies a pending autofocus only while the target scope has no
  /// focused child, so an autofocus resolved against the route scope is
  /// discarded whenever anything in the player already holds focus. A scope of
  /// the card's own is empty by definition, so the autofocus on the primary
  /// action lands.
  final FocusScopeNode _cardScope = FocusScopeNode(debugLabel: 'ended-card');

  /// Whether the player's own route is the one the remote belongs to.
  ///
  /// The card is raised by an engine event, so it can mount while a panel is
  /// open over the player. A route underneath a pushed route stays focusable —
  /// the framework expresses currency as `skipTraversal` alone
  /// (`_ModalScopeState.build`) and withholds `canRequestFocus` only while a
  /// route is animating out or under a user gesture — so both the scope grab
  /// and the autofocus would otherwise reach across the barrier and put the
  /// remote on a button the barrier covers.
  ///
  /// `_ModalScopeStatus` is an [InheritedModel] keyed on this aspect, so
  /// reading it rebuilds the card when a route is pushed over the player or
  /// popped off it. That is what hands the remote to a card waiting behind a
  /// panel: `autofocus` flips true, `Focus.didUpdateWidget` re-arms it, and
  /// the scope grab runs again.
  bool _routeIsCurrent = true;

  @override
  void initState() {
    super.initState();
    // didChangeDependencies runs before the first build, so [_routeIsCurrent]
    // is accurate by the time the post-frame grab reads it.
    _grabRemoteAfterFrame();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final wasCurrent = _routeIsCurrent;
    _routeIsCurrent = ModalRoute.isCurrentOf(context) ?? true;
    // Only on the way back to current: a panel closing over a card that is
    // already up is the one case [initState]'s grab cannot cover.
    if (_routeIsCurrent && !wasCurrent) _grabRemoteAfterFrame();
  }

  /// See [_cardScope]. After the frame, because the scope has no parent — and
  /// so nothing to be focused within — until the first build has attached it.
  void _grabRemoteAfterFrame() {
    if (!widget.isTv) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _routeIsCurrent) _cardScope.requestFocus();
    });
  }

  @override
  void dispose() {
    _cardScope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final compact = MediaQuery.sizeOf(context).shortestSide < 600;
    final actions = <Widget>[
      if (widget.onNextEpisode case final next?)
        _EndedButton(
          icon: Icons.skip_next_rounded,
          label: widget.nextLabel ?? l10n.next,
          filled: true,
          isTv: widget.isTv,
          // Gated on [_routeIsCurrent] too: an autofocus resolves against
          // this card's own scope, which is empty whether or not a panel is
          // up, so guarding the scope grab alone would do nothing.
          autofocus: widget.isTv && _routeIsCurrent,
          debugLabel: kEndedNextFocusLabel,
          onPressed: next,
        ),
      _EndedButton(
        icon: Icons.replay_rounded,
        label: l10n.startOver,
        // Primary only when nothing follows: with a declined episode on the
        // card, Next is the common case and keeps the remote.
        filled: widget.onNextEpisode == null,
        isTv: widget.isTv,
        autofocus:
            widget.isTv && widget.onNextEpisode == null && _routeIsCurrent,
        debugLabel: kEndedStartOverFocusLabel,
        onPressed: widget.onStartOver,
      ),
      _EndedButton(
        icon: Icons.close_rounded,
        label: l10n.close,
        filled: false,
        isTv: widget.isTv,
        debugLabel: kEndedCloseFocusLabel,
        onPressed: widget.onClose,
      ),
    ];

    return RepaintBoundary(
      child: ColoredBox(
        // Not opaque: a trace of the last frame under the words is the
        // difference between "this finished" and "the app closed the video".
        color: Colors.black.withValues(alpha: 0.92),
        child: FocusScope(
          node: _cardScope,
          child: FocusTraversalGroup(
            policy: ReadingOrderTraversalPolicy(),
            child: SafeArea(
              // The overscan token applies on a television, and this surface
              // is full-bleed by construction.
              minimum: EdgeInsets.all(
                widget.isTv
                    ? HotstarPlayerStyle.tvEdgeInset
                    : HotstarPlayerStyle.edgeInset,
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.playerFinished(widget.title),
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: HotstarPlayerStyle.primaryText,
                        fontSize: widget.isTv ? 30 : (compact ? 20 : 24),
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                    SizedBox(height: widget.isTv ? 32 : 24),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      alignment: WrapAlignment.center,
                      children: actions,
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

/// One action, as one focus stop.
///
/// Not [PlayerActionButton]: that widget leaves its `InkWell` focusable, so
/// each of its buttons is two focus stops at identical geometry, and it
/// carries no `debugLabel` for a test to find. On a card that is the only
/// thing on screen, half of every D-pad press would do nothing.
///
/// The shape is [NextEpisodeCountdown]'s `_CardButton` — a [Focus] handling
/// the activation keys over an [InkWell] that cannot take focus — with a
/// leading icon and the television type ramp.
class _EndedButton extends StatefulWidget {
  const _EndedButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.filled,
    required this.isTv,
    required this.debugLabel,
    this.autofocus = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool filled;
  final bool isTv;
  final String debugLabel;
  final bool autofocus;

  @override
  State<_EndedButton> createState() => _EndedButtonState();
}

class _EndedButtonState extends State<_EndedButton> {
  bool _focused = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (isPlayerActivation(event.logicalKey)) {
      widget.onPressed();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    // The ring is for whoever is driving the player without a pointer, on
    // every form factor - it used to be gated on `isTv`, which left a phone
    // with a hardware keyboard and a desktop window with no focus cue at all.
    final ring = showFocusIndicator(context, _focused);
    final Color border = ring
        ? HotstarPlayerStyle.focusRing
        : (widget.filled ? Colors.transparent : HotstarPlayerStyle.divider);
    // The ten-foot ramp the panel's row labels use.
    final double fontSize = widget.isTv ? 17 : 14;

    return Semantics(
      button: true,
      label: widget.label,
      child: Focus(
        debugLabel: widget.debugLabel,
        autofocus: widget.autofocus,
        onKeyEvent: _onKey,
        onFocusChange: (value) => setState(() => _focused = value),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: widget.onPressed,
            // One control, one focus stop. Left focusable, the InkWell makes a
            // node of its own at the same geometry that answers no keys.
            canRequestFocus: false,
            borderRadius: BorderRadius.circular(10),
            child: AnimatedContainer(
              duration: HotstarPlayerStyle.fastMotionDuration,
              constraints: BoxConstraints(minHeight: widget.isTv ? 52 : 44),
              padding: EdgeInsets.symmetric(horizontal: widget.isTv ? 20 : 16),
              decoration: BoxDecoration(
                color: widget.filled
                    ? HotstarPlayerStyle.accent
                    : (ring
                          ? HotstarPlayerStyle.focusFill
                          : Colors.transparent),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: border,
                  width: ring ? HotstarPlayerStyle.focusRingWidth : 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    widget.icon,
                    color: Colors.white,
                    size: widget.isTv ? 22 : 18,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: fontSize,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
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
