import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/thumbnail_error_placeholder.dart';
import '../widgets/hotstar_player_style.dart';
import '../widgets/player_activation.dart';
import '../widgets/player_control_components.dart';

/// The "up next" card shown in the closing seconds of an episode.
///
/// Engine-agnostic and stateless about playback, exactly like [PlayerRail]:
/// every value it renders and both outcomes are handed in. The old
/// NextEpisodeOverlay was armed from player_controller.dart:2122-2157 and then
/// read the controller back for `isPlaying`, so the countdown had two owners.
/// Here [paused] is a plain bool in, which is why this file imports nothing of
/// the engine or its controller - only the chrome's shared tokens and metrics -
/// and can be tested without one.
///
/// Contract, because auto-advance is destructive and a double fire skips two
/// episodes: **exactly one of [onPlayNext] and [onCancel] is ever called, and
/// it is called at most once.** The parent unmounts the card in response to
/// either. After [onCancel] it must not be shown again for this episode —
/// "cancel" means the viewer declined the advance, not "ask again in a second".
///
/// ## Composition
///
/// Two layouts, chosen by form factor and *measured*, not guessed:
///
/// * **Stacked** (TV, desktop, tablet). The reference design's shape: a
///   full-width still across the top of the card - 16:9 where the viewport
///   has the height for it and a `BoxFit.cover` crop of the same frame where
///   it does not, see [_NextEpisodeCountdownState._stacked] - then a dark panel
///   carrying the `S1 E2` pill, the title and a two-line synopsis, then the two
///   actions. The countdown ring — which the reference has no equivalent for,
///   and which is the only thing telling the viewer this will happen by itself
///   — rides in the UP NEXT badge floated over the still's top-left corner,
///   or, when there is no still, as the panel's first row.
/// * **Compact** (a phone held sideways). Stays the row it was, thumbnail
///   beside the text. See [_kCompactWidth] for the arithmetic: the stacked
///   shape does not fit in a phone's landscape height.
///
/// ## The three numbers the layout is solved against
///
/// Everything below is measured on the 960x540 dp canvas a 1080p television
/// reports, which is the tightest of the three form factors by a wide margin:
///
/// * [_bottomClearance] — the card is anchored above the scrubber.
/// * [_kTopChromeHeight] — and below the running title, see [_available].
/// * The widest action label in the shipped locales, which is what fixes the
///   card's *width*: see [_kTvWidth] and [_actions].
///
/// The still is what gives when those three do not leave room: it is the one
/// [Flexible] child of the stacked column, so the card's height is bounded by
/// construction rather than by an arithmetic budget that a longer string or a
/// larger text scale can silently blow past.
class NextEpisodeCountdown extends StatefulWidget {
  const NextEpisodeCountdown({
    required this.title,
    required this.onPlayNext,
    required this.onCancel,
    this.posterUrl,
    this.season,
    this.episode,
    this.rating,
    this.runtime,
    this.description,
    this.countdown = const Duration(seconds: 15),
    this.paused = false,
    this.isTv = false,
    super.key,
  });

  /// Title of the episode that will play, not of the series.
  final String title;

  /// Episode still or series poster. Null is a real case — a series with no
  /// episode art — and the two layouts answer it differently; see
  /// [_stacked] and [_Thumbnail].
  final String? posterUrl;

  final int? season;
  final int? episode;

  /// Out of 10, matching the catalogue's scale. Null or <= 0 hides it.
  final double? rating;

  /// Episode runtime. Anything under a minute is treated as unknown — a
  /// handful of seconds is metadata noise, not a runtime.
  final Duration? runtime;

  final String? description;

  /// How long before the advance happens on its own. Matches the old
  /// overlay's 15 s.
  final Duration countdown;

  /// Holds the countdown where it is. Playback pausing must not burn the
  /// timer down: the viewer who pauses at the credits is the one most likely
  /// to be reading this card.
  final bool paused;

  final bool isTv;

  /// Fired by "Play now" and by the countdown reaching zero. The card does not
  /// distinguish them because the outcome is identical.
  final VoidCallback onPlayNext;

  /// The viewer declined. Nothing else happens — the episode plays out.
  final VoidCallback onCancel;

  @override
  State<NextEpisodeCountdown> createState() => _NextEpisodeCountdownState();
}

/// Card width on a television, and the one number in this file that is a
/// *derivation* rather than a taste call.
///
/// It is derived from the **longest action label**, not from the height budget
/// it used to be solved against. A clipped primary action is not shippable,
/// and the widest of the three shipped locales is Kannada: `playNow` is
/// "ಈಗಲೇ ಪ್ಲೇ ಮಾಡಿ", which lays out at **224 dp** at the ten-foot 16 sp
/// (`RenderParagraph.maxIntrinsicWidth`, measured — Hindi is 144 and English
/// 128). The two actions are stacked rather than side by side precisely so
/// each of them gets the card's whole width; splitting 272 dp in half left
/// 97 dp for a 224 dp string and every locale ellipsised, English included.
///
/// So: `224 label + 2 x 10 button padding + 2 x 14 card padding = 272` exactly,
/// rounded up to 300 for a tenth of slack over the longest string we ship.
/// 300 dp is 31 % of a 960 dp canvas — the reference's "roughly a third".
///
/// The height is *not* solved here any more. See [_available] and [_stacked]:
/// the panel takes what it needs and the still takes what is left, capped at
/// 16:9. On a 960x540 set with full catalogue data that leaves the still 78 dp
/// of the card's 304 — measured, and the reason the synopsis is still two
/// lines while the title is one.
const double _kTvWidth = 300;

/// Desktop and tablet. Height is not the binding constraint here: the layout
/// is only reached when the shortest side is >= 600 dp. 400 - 28 - 20 = 352 dp
/// of label per action against Kannada's 182 dp at 13 sp.
const double _kWideWidth = 400;

/// A phone held sideways is ~390 dp tall, of which the card may use
/// `390 - 144 - 92 = 154` once it is held clear of both the 123 dp bottom bar
/// and the title above — which is under the floor, so what it actually gets is
/// [_kMinCardHeight] and the clearance over the *title* is what gives.
/// The stacked shape does not fit in that, and this is measured rather than
/// argued: forced down that branch the panel alone wants 237 dp - its two
/// title lines, two synopsis lines and two stacked actions are width-
/// independent - and the framework reports "A RenderFlex overflowed by 77
/// pixels on the bottom" before the still has taken a single dp.
///
/// So compact keeps the row it had: a thumbnail beside the text, and it lays
/// out at 218 dp with 8 to spare. A full-bleed still over a 149 dp-tall video
/// is not a card, it is a takeover. The width answers the same label question
/// [_kTvWidth] does: `300 - 24 - 20 = 256` dp per stacked action, against
/// Kannada's 185.5 dp at the touch 13 sp.
const double _kCompactWidth = 300;

/// The band the player's top bar occupies, which the card is held clear of.
///
/// Measured through the real screen at 960x540: `PlayerTopBar` lays out
/// 0..92 dp and its title — an `Expanded` with `maxLines: 1`, so a real series
/// title does fill it to the overscan inset at x = 912 — paints 34..65. The
/// card is bottom-right and 272 dp wide, so it shares those columns; before
/// this it topped out at 47 dp and ate the lower 18 dp of the running title.
///
/// One constant for all three form factors rather than three: the ten-foot bar
/// is the tallest of them (the touch bar sets its title at 18 sp, not 22), so
/// 92 is conservative everywhere else. It is deliberately *not* conditional on
/// the chrome being visible — the card can be up with the bars hidden, and a
/// card whose size depends on whether the bars happen to be up would resize
/// under the viewer every time they tapped.
const double _kTopChromeHeight = 92;

/// Clearance over the scrubber, from the shared chrome token so the card
/// follows the bottom bar instead of repeating its metrics.
///
/// ONE number for the flat bar, on every form factor, and that is the fix.
/// The compact branch used to carry a second, smaller estimate of its own —
/// 60 dp, on the theory that a phone's bar is much shorter than a
/// television's — and it was wrong by more than half. Measured through the
/// real [PlayerBottomBar], whose height is content-driven and so has to be
/// read off the widget rather than argued from its parts:
///
/// | bar                                   | height |
/// | ------------------------------------- | ------ |
/// | ten-foot                              | 137    |
/// | one flat control row (touch, tablet, desktop) | 123 (124 live) |
/// | touch, action strip on its own run    | 171 (172 live) |
///
/// `60 + 12` put the card's last 51 dp *over* the scrubber on every phone —
/// and the card is a later child of the player's Stack than the controls
/// (vlc_player_screen.dart builds `VlcPlayerControls` and then
/// `_nextEpisodeCard`), so it did not merely cover the right third of the seek
/// bar, it hit-tested in front of it and ate the drags aimed at it. The last
/// fifteen seconds of an episode is exactly when a viewer reaches for that end
/// of the bar to get back into the scene.
///
/// `bottomChromeHeight + 12` = 144 clears the two flat bars — 7 dp over the
/// taller — which is what a shared chrome token is for. Measured through the
/// real screen at 960x540: `PlayerBottomBar` starts at 403 dp and this puts
/// the card's last pixel on 396.
const double _kBottomClearance = HotstarPlayerStyle.bottomChromeHeight + 12;

/// What the bar grows by when its action strip takes a run of its own, which
/// on a portrait handset it does: `171 - 123`, one [PlayerIconButton] row.
/// See [PlayerBottomBar.narrowTouchWidth] for when.
const double _kActionRunHeight = 48;

/// The clearance the card actually gets.
///
/// Two corrections to the flat [_kBottomClearance], in this order.
///
/// **Up, for the two-row bar.** Below [PlayerBottomBar.narrowTouchWidth] of
/// *inner* width the bar puts its action strip on a run above the transport
/// row and stands 48 dp taller, so the card has to stand 48 dp higher. The
/// threshold is read off the bar's own constant and applied to the same inner
/// width the bar measures — the viewport less the two edge insets it pads by —
/// so the card cannot disagree with the bar about which shape the bar is in.
/// It needs no `isTouch` of its own to do it: the split is a touch behaviour,
/// and every viewport narrow enough to reach it is a handset held upright.
/// A desktop window cannot be one (macOS `contentMinSize`, the Win32
/// `ptMinTrackSize` and GTK's `size_request` all floor the window at 800x600),
/// and no phone in landscape is under 568 dp.
///
/// **Down, when there is no room.** The clearance is a *preference*, and on a
/// viewport too short to hold the card above the bar at all it is the first
/// thing that gives — before the card breaks. [_kMinCardHeight] is reserved
/// out of the viewport and what is left over is the clearance: a 390 dp-tall
/// phone affords all 144, a 360 dp one 136, a 320 dp one 96, where 218 of card
/// and 123 of bar want 341 dp of a 320 dp screen and something has to overlap.
/// Without this the fix for the overlap would trade it for a worse defect —
/// the [Padding] in [build] hands the card `size.height - clearance`, so a
/// flat 144 on a 360 dp-tall phone leaves 216 for a card that measures 218 and
/// the framework reports "A RenderFlex overflowed by 2.0 pixels on the
/// bottom", 34 at 320.
double _bottomClearance(
  Size size,
  EdgeInsets padding, {
  required double edge,
  required bool isTv,
}) {
  // The bar's own arithmetic, from PlayerBottomBar.build.
  final double left = isTv ? edge : math.max(padding.left, edge);
  final double right = isTv ? edge : math.max(padding.right, edge);
  final double inner = size.width - left - right;
  final double preferred = inner < PlayerBottomBar.narrowTouchWidth
      ? _kBottomClearance + _kActionRunHeight
      : _kBottomClearance;
  final double room = size.height - padding.bottom - _kMinCardHeight;
  return math.min(preferred, math.max(0.0, room));
}

/// The largest text scale the card honours.
///
/// The card cannot scroll and cannot grow: it is pinned between the running
/// title above it and the scrubber below it, and on the branch that matters
/// most it has 304 dp to work with. Left to honour the full accessibility
/// range it overflowed — measured at 1000x600 with full catalogue data, scale
/// 1.6 printed "A RenderFlex overflowed by 7.0 pixels on the bottom", 1.75
/// gave 20 and 2.0 gave 39.
///
/// 1.3 is not an arbitrary retreat: it is the top of Android's *Display*
/// font-size setting, so every scale a viewer can reach without opening
/// Accessibility is honoured in full. Past that the card holds its type and
/// keeps its geometry rather than clipping the action the countdown is about
/// to take. TV never reaches this — main.dart pins `TextScaler.noScaling`
/// there — so this is a touch and desktop rule.
const double _kMaxTextScale = 1.3;

/// The clearance over the *title* is a preference; this is the card's floor,
/// and on a short enough viewport the floor wins.
///
/// A 360 dp-wide phone - which is the commonest Android width there is - is
/// 360 dp tall held sideways, and `360 - 144 chrome - 92 title` is 124 against
/// a compact card that measures 218 at every scale it honours. Measured:
/// without this the framework reports "A RenderFlex overflowed by 94 pixels on
/// the bottom" there. Given the choice between a card that overlaps the top
/// bar on a small phone and a card that is broken on one, the overlap is the
/// right answer - and it is the branch where the overlap is least serious,
/// because the touch title paints at 18 sp and ends well above the 92 the
/// ten-foot bar occupies, and because the only *control* in the top bar is
/// Back, which is at the far left of a bar this right-anchored card never
/// reaches.
///
/// It is also the reserve [_bottomClearance] hands back to the viewport, so
/// the two rules cannot fight: the clearance over the scrubber is given up a
/// dp at a time to keep this whole, and the card breaks only when the bar and
/// the floor together do not fit on the screen at all.
///
/// 224 rather than 218 exactly: the six spare dp are for a locale whose
/// two-line action label would push a slab past 44 dp.
const double _kMinCardHeight = 224;

class _NextEpisodeCountdownState extends State<NextEpisodeCountdown>
    with SingleTickerProviderStateMixin {
  /// One clock, not a timer plus an animation. The old overlay ran a [Timer]
  /// for the deadline alongside an [AnimationController] for the ring and had
  /// to reconcile them by hand across pause and resume (`_elapsedFraction`);
  /// driving the deadline off the controller's own completion means the ring
  /// cannot disagree with the moment it fires.
  late final AnimationController _clock;

  /// Latches on the first outcome so neither callback can fire twice — a
  /// second [onPlayNext] would skip an episode nobody asked to skip.
  bool _settled = false;

  /// The card's own focus scope, and the whole reason the remote can reach it.
  ///
  /// Flutter applies a pending autofocus only while the target scope has no
  /// focused child (`_Autofocus.applyIfValid` in focus_manager.dart). The card
  /// is a *sibling* of the controls in the player's Stack, and the controls
  /// guarantee the route scope always has a focused child — a chrome button,
  /// or their key sink, which exists for exactly that reason. So an autofocus
  /// resolved against the route scope was discarded every single time and
  /// "Play now" never took the remote: on a television the countdown ran down
  /// to a destructive auto-advance with no focus ring anywhere to aim at.
  ///
  /// A scope of the card's own is empty by definition, so the autofocus on the
  /// Play-now button lands: applying it walks the scope chain and makes this
  /// scope the route's focused child on the way. That is the whole mechanism —
  /// verified by ablation, the scope alone carries tv_overlay_focus_test. The
  /// post-frame [FocusScopeNode.requestFocus] in [_grabRemoteAfterFrame] is a
  /// rescue for the one case the autofocus cannot cover: an autofocus is
  /// discarded, permanently, if anything has already been focused inside this
  /// scope by the time the manager gets to it, whereas a request is not gated
  /// on `focusedChild`. It cannot fight the autofocus — a request on a scope
  /// with no focused child only marks the scope, and the autofocus then
  /// resolves it onto Play now in the same pass.
  ///
  /// The controls cannot take the focus back. Their sink only reclaims when
  /// primary focus is a [FocusScopeNode] that is an *ancestor* of the sink,
  /// and this scope is a sibling.
  final FocusScopeNode _cardScope = FocusScopeNode(
    debugLabel: 'next-episode-card',
  );

  /// Whether the player route is the one the remote belongs to.
  ///
  /// The card is raised off a position sample, so it can mount while a panel
  /// is open over the player. That panel is a [PopupRoute]
  /// (panel/player_panel.dart), so the player route underneath stays built and
  /// focusable — Flutter only stops a route taking focus while it is animating
  /// out or under a user gesture, never merely because something was pushed
  /// over it. Both of the grabs below therefore reach *across* the modal:
  /// [FocusScopeNode.requestFocus] on an empty scope re-points every ancestor
  /// scope, the navigator's included, and the autofocus on Play now then lands
  /// because this scope is empty by construction. The panel is left on screen
  /// with the remote on a control underneath the barrier, and the first Back
  /// is eaten by [_onCardKey] instead of popping it.
  ///
  /// So both are gated on this. `_ModalScopeStatus` is an [InheritedModel]
  /// keyed on exactly this aspect, so depending on it in [build] rebuilds the
  /// card when a route is pushed over the player or popped off it — which is
  /// what hands the remote to a card that has been waiting behind a panel: the
  /// `autofocus` flips true and `Focus.didUpdateWidget` re-arms it (it was
  /// never spent), and [didChangeDependencies] re-runs the scope rescue.
  bool _routeIsCurrent = true;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(vsync: this, duration: widget.countdown)
      ..addStatusListener(_onClockStatus);
    if (!widget.paused) _clock.forward();
    // Safe to schedule before the route is looked up: didChangeDependencies
    // and the first build both run before a post-frame callback does, so
    // [_routeIsCurrent] is already true to the tree by the time it fires.
    _grabRemoteAfterFrame();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final wasCurrent = _routeIsCurrent;
    _routeIsCurrent = ModalRoute.isCurrentOf(context) ?? true;
    // Only on the transition back to current: a panel closing over a card that
    // is already up is the one case the initial grab cannot cover.
    if (_routeIsCurrent && !wasCurrent) _grabRemoteAfterFrame();
  }

  /// See [_cardScope]. After the frame, because the scope has no parent - and
  /// so nothing to be focused within - until the first build has attached it;
  /// this is the rescue for a frame in which the autofocus was already spent.
  void _grabRemoteAfterFrame() {
    if (!widget.isTv) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _routeIsCurrent) _cardScope.requestFocus();
    });
  }

  @override
  void didUpdateWidget(covariant NextEpisodeCountdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.paused == oldWidget.paused || _settled) return;
    // forward() resumes from wherever stop() left the value, so pause/resume
    // needs no bookkeeping of its own.
    widget.paused ? _clock.stop() : _clock.forward();
  }

  @override
  void dispose() {
    _clock.dispose();
    _cardScope.dispose();
    super.dispose();
  }

  void _onClockStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _settle(widget.onPlayNext);
  }

  void _settle(VoidCallback outcome) {
    if (_settled) return;
    _settled = true;
    _clock.stop();
    outcome();
  }

  /// Back/Escape while focus is inside the card means "no", not "leave the
  /// player". Only reached when the card actually holds focus, so it cannot
  /// swallow a Back the viewer aimed at the route.
  KeyEventResult _onCardKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      _settle(widget.onCancel);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The height the card is allowed to occupy: the viewport, less the band the
  /// running title is in ([_kTopChromeHeight]) and the band the scrubber is in
  /// ([_bottomClearance]). Handed to the card as a hard `maxHeight`, which is
  /// what makes the top-bar clearance a *guarantee* rather than the outcome of
  /// an arithmetic height budget — the still gives instead.
  double _available(Size size, EdgeInsets padding, {required double edge}) {
    final free =
        size.height -
        _bottomClearance(size, padding, edge: edge, isTv: widget.isTv) -
        padding.bottom -
        _kTopChromeHeight -
        padding.top;
    return math.max(_kMinCardHeight, free);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // isTv first, compact only as the non-TV fallback — the shape ended_card
    // uses. A 1080p television reports 960x540 dp (a Shield, a Google TV and a
    // Fire TV all present 1920x1080 at devicePixelRatio 2), so a bare
    // `shortestSide < 600` is TRUE on every set and would shadow every branch
    // below: the ten-foot card would be laid out as a 300 dp phone card and
    // floated only 72 dp up, over the bottom bar it is written to clear.
    final size = MediaQuery.sizeOf(context);
    final compact = !widget.isTv && size.shortestSide < 600;
    final padding = MediaQuery.viewPaddingOf(context);
    final edge = widget.isTv
        ? HotstarPlayerStyle.tvEdgeInset
        : HotstarPlayerStyle.edgeInset;

    final double width = compact
        ? _kCompactWidth
        : (widget.isTv ? _kTvWidth : _kWideWidth);

    return MediaQuery.withClampedTextScaling(
      // See [_kMaxTextScale]: the card has no room to grow into and nowhere to
      // scroll, so it honours the Display range and holds past it.
      maxScaleFactor: _kMaxTextScale,
      child: Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: EdgeInsets.only(
            right: widget.isTv
                ? edge
                : (padding.right > edge ? padding.right : edge),
            bottom:
                _bottomClearance(size, padding, edge: edge, isTv: widget.isTv) +
                padding.bottom,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: _available(size, padding, edge: edge),
            ),
            child: FocusScope(
              node: _cardScope,
              onKeyEvent: _onCardKey,
              child: FocusTraversalGroup(
                child: SizedBox(
                  width: width,
                  child: DecoratedBox(
                    // A solid translucent panel, not a BackdropFilter. The card is
                    // composited over the native video surface, and a blur forces
                    // a readback of that surface on every repaint — every frame
                    // here, because the ring is driven by an AnimationController
                    // and so repaints on each vsync, not once per counted second.
                    decoration: BoxDecoration(
                      color: HotstarPlayerStyle.panel.withValues(alpha: 0.94),
                      borderRadius: BorderRadius.circular(_kRadius),
                    ),
                    // The border paints in *front* of the content, which the
                    // default [DecorationPosition.background] does not: the still
                    // is flush to the card's top and both sides, so a background
                    // border was overpainted by the image along the whole top edge
                    // and the top of the sides. Against a bright frame the card
                    // then had no outline where it needed one most.
                    child: DecoratedBox(
                      position: DecorationPosition.foreground,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(_kRadius),
                        border: Border.all(
                          color: HotstarPlayerStyle.divider,
                          width: _kBorderWidth,
                        ),
                      ),
                      child: compact ? _compact(l10n) : _stacked(l10n, width),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The reference composition: still, then panel, then the two actions.
  ///
  /// The still is the column's one [Flexible] child, which is the whole shape
  /// of the height contract. The panel is inflexible and lays out at whatever
  /// its text needs; the still then takes what is left, capped at 16:9 by the
  /// [AspectRatio] and cropped by `BoxFit.cover` below that. So the card is
  /// bounded by the box [build] hands it — it clears the running title above
  /// and the scrubber below by construction, at any text scale the card
  /// honours, in any locale — instead of by a height budget that a longer
  /// string could silently blow past. Measured on a 960x540 set with full
  /// catalogue data: panel 226, still 78, card 304.
  ///
  /// A missing still is *not* rendered as a full-width placeholder. That is a
  /// 300x78 dp letterbox with a broken-image glyph floating in the middle of
  /// it, which is worse than no still at all; the badge simply becomes the
  /// panel's first row instead and the card gives the 78 dp back. The
  /// on-device placeholder still backs the case that matters — a still that is
  /// *offered* and fails to load, where the box is already laid out
  /// (see [_Still]).
  Widget _stacked(AppLocalizations l10n, double width) {
    final url = widget.posterUrl;
    final hasStill = url != null && url.isNotEmpty;
    final description = widget.description;
    final hasSynopsis = description != null && description.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasStill)
          Flexible(
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: _Still(
                url: url,
                width: width,
                badge: _badge(l10n, onStill: true),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!hasStill) ...[
                _badge(l10n, onStill: false),
                const SizedBox(height: 10),
              ],
              if (_metaRow(compact: false) case final row?) ...[
                row,
                const SizedBox(height: 8),
              ],
              _title(compact: false),
              if (hasSynopsis) ...[
                const SizedBox(height: 6),
                Text(
                  description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: HotstarPlayerStyle.mutedText,
                    fontSize: widget.isTv ? 14 : 13,
                    // Explicit, so the panel's height is arithmetic rather than
                    // a property of whichever font the platform resolves —
                    // Hindi and Kannada glyphs are taller than Latin, and the
                    // still's share is whatever this leaves.
                    height: 1.3,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              _actions(l10n),
            ],
          ),
        ),
      ],
    );
  }

  /// A phone held sideways: the row, kept. See [_kCompactWidth].
  Widget _compact(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _badge(l10n, onStill: false),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 96x54 dp of placeholder is a chip, not the hole the stacked
              // layout refuses; the row would otherwise reflow around nothing.
              _Thumbnail(url: widget.posterUrl, width: 96),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_metaRow(compact: true) case final row?) ...[
                      row,
                      const SizedBox(height: 4),
                    ],
                    _title(compact: true),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _actions(l10n),
        ],
      ),
    );
  }

  /// One line on every branch but the desktop one.
  ///
  /// The reference's own card sets the episode title on a single line, and on
  /// the two branches that are short of height it is the cheapest 21.6 dp
  /// there is: on a television the second line came straight out of the still,
  /// and on a phone out of the clearance over the scrubber.
  Widget _title({required bool compact}) {
    return Text(
      widget.title,
      maxLines: (compact || widget.isTv) ? 1 : 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: HotstarPlayerStyle.primaryText,
        fontSize: compact ? 14 : (widget.isTv ? 18 : 16),
        fontWeight: FontWeight.w700,
        height: 1.2,
      ),
    );
  }

  /// UP NEXT and the countdown ring, together.
  ///
  /// The label survives from the old card and the ring has no counterpart in
  /// the reference at all — it is the only thing on screen saying the advance
  /// will happen by itself — so they are one unit and travel together. Over a
  /// still they ride in a scrim-backed chip in its top-left corner; with no
  /// still they are the panel's first row.
  Widget _badge(AppLocalizations l10n, {required bool onStill}) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.upNext.toUpperCase(),
          // 14 on TV, not the 12 it was. The eyebrow could have been argued
          // as a graphic mark rather than a string and left under the floor,
          // but it costs nothing to clear it: the badge's height is the 30 dp
          // ring's, not the label's, so this is 2 sp for free.
          style: TextStyle(
            color: HotstarPlayerStyle.accent,
            fontSize: widget.isTv ? 14 : 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.6,
            height: 1.2,
          ),
        ),
        const SizedBox(width: 8),
        _CountdownRing(
          clock: _clock,
          total: widget.countdown,
          isTv: widget.isTv,
        ),
      ],
    );

    if (!onStill) return row;
    return DecoratedBox(
      // A flat translucent fill, not a blur: this sits over the still, and the
      // ring under it repaints every vsync. Opaque enough that the label holds
      // against a bright frame.
      decoration: BoxDecoration(
        color: HotstarPlayerStyle.panel.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
        child: row,
      ),
    );
  }

  /// The `S1 E2` pill, with the episode number carrying the emphasis, followed
  /// by whatever else the catalogue knows. Null when it knows nothing — a row
  /// of empty separators looks broken.
  Widget? _metaRow({required bool compact}) {
    final pill = _pill(compact: compact);
    final meta = _meta;
    if (pill == null && meta == null) return null;

    return Row(
      children: [
        ?pill,
        if (pill != null && meta != null) const SizedBox(width: 8),
        if (meta != null)
          // Flexible, because this is the row that has to give: a long runtime
          // beside a wide pill on a 300 dp TV card must ellipsise rather than
          // overflow.
          Flexible(
            child: Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: HotstarPlayerStyle.secondaryText,
                // 14 on TV, not the 12 it was: 12 sp is 24 real pixels on a
                // 1080p set and this row carries the runtime and the rating,
                // which are the two things a viewer actually reads off it.
                // The ten-foot floor is 14 (panel/player_panel_metrics.dart)
                // and the 2 dp it costs comes out of the still.
                fontSize: widget.isTv ? 14 : 11,
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
            ),
          ),
      ],
    );
  }

  Widget? _pill({required bool compact}) {
    final season = widget.season;
    final episode = widget.episode;
    if (episode == null) return null;

    // See [_metaRow]: 14 is the ten-foot floor, and the season/episode number
    // is the single most-read string on the card after the title.
    final double size = compact ? 10 : (widget.isTv ? 14 : 11);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: HotstarPlayerStyle.divider,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 8, vertical: 4),
        child: Text.rich(
          TextSpan(
            children: [
              if (season != null)
                TextSpan(
                  text: 'S$season ',
                  style: const TextStyle(
                    color: HotstarPlayerStyle.secondaryText,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              TextSpan(
                text: 'E$episode',
                style: const TextStyle(
                  color: HotstarPlayerStyle.primaryText,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: size,
            height: 1.0,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }

  /// `42m · ★ 8.1` — everything the pill does not carry, each part optional.
  String? get _meta {
    final parts = <String>[];

    final runtime = widget.runtime;
    if (runtime != null && runtime.inMinutes >= 1) {
      final hours = runtime.inHours;
      final minutes = runtime.inMinutes.remainder(60);
      parts.add(hours > 0 ? '${hours}h ${minutes}m' : '${minutes}m');
    }

    final rating = widget.rating;
    if (rating != null && rating > 0) {
      parts.add('★ ${rating.toStringAsFixed(1)}');
    }

    return parts.isEmpty ? null : parts.join('  ·  ');
  }

  /// Two actions of equal prominence, **stacked**, each the card's full width.
  ///
  /// Side by side they were 117 dp each on a 272 dp television card, of which
  /// 97 dp was label. Measured against that budget at the ten-foot 16 sp:
  /// English "Play Now" wants 128 dp, Hindi "अभी चलाएं" 144 and Kannada
  /// "ಈಗಲೇ ಪ್ಲೇ ಮಾಡಿ" 224 — every locale we ship reported
  /// `didExceedMaxLines`, and the primary action of a destructive
  /// auto-advance was ellipsised in all three. Widening the card until a *row*
  /// held Kannada needs 526 dp, over half the screen.
  ///
  /// Stacking hands each label the whole card instead: 240 dp at 300 dp of TV
  /// card, 352 on desktop, 256 on the compact phone strip. It costs 52 dp of
  /// height, which comes out of the still (see [_stacked]) rather than out of
  /// the viewport, and it costs the row's left/right traversal — the D-pad
  /// walks Play now → Cancel with Down now, not Right.
  ///
  /// Play now stays first in the tree, so native traversal reaches it first
  /// and the autofocus lands on the one the timeout is about to take anyway.
  Widget _actions(AppLocalizations l10n) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CardButton(
          label: l10n.playNow,
          filled: true,
          isTv: widget.isTv,
          // The remote lands here because activating it is what the countdown
          // is about to do anyway — an accidental select costs nothing, while
          // landing on Cancel would make the common case the slow one. This
          // only resolves the card's scope onto a child; what brings the
          // remote into the scope at all is [_cardScope], and [_routeIsCurrent]
          // is why neither reaches over an open panel.
          autofocus: widget.isTv && _routeIsCurrent,
          debugLabel: kPlayNextFocusLabel,
          onPressed: () => _settle(widget.onPlayNext),
        ),
        const SizedBox(height: _kActionGap),
        _CardButton(
          label: l10n.cancel,
          filled: false,
          isTv: widget.isTv,
          debugLabel: kCancelFocusLabel,
          onPressed: () => _settle(widget.onCancel),
        ),
      ],
    );
  }
}

/// Focus node labels. Public so the integration and the tests can assert where
/// the remote is without either of them owning a [FocusNode] — the card's only
/// node is the scope that carries the remote into it, so traversal *between*
/// its two controls stays entirely native.
const String kPlayNextFocusLabel = 'next_episode_play_now';
const String kCancelFocusLabel = 'next_episode_cancel';

/// The card's corner radius, shared by the panel and by the clip on the still
/// that has to meet it.
const double _kRadius = 14;

/// The card's outline. The still is clipped to the *inner* radius, one border
/// width in from the outer one, so the image corner does not sit proud of the
/// line drawn over it.
const double _kBorderWidth = 1;
const double _kInnerRadius = _kRadius - _kBorderWidth;

/// The gap between the two stacked actions. See [_NextEpisodeCountdownState.
/// _actions]: two 44 dp slabs and this is 96 dp of the card's height.
const double _kActionGap = 8;

/// The minimum height a rendered action slab may report, and the one number
/// the focus ring needs: a 44 dp target is the shared chrome's rule.
const double _kActionHeight = 44;

/// Ring plus remaining seconds, repainting in isolation.
///
/// Its own [RepaintBoundary] because it is the only part of the card that
/// changes: without one, every frame of the ring would repaint the still,
/// the text and the buttons on a layer sitting over the video surface.
class _CountdownRing extends StatelessWidget {
  const _CountdownRing({
    required this.clock,
    required this.total,
    required this.isTv,
  });

  final Animation<double> clock;
  final Duration total;
  final bool isTv;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: clock,
        builder: (context, _) {
          final remaining = total * (1 - clock.value);
          // Ceil so the ring reads "15" the instant it appears and only shows
          // "0" at the moment it fires.
          final seconds = (remaining.inMilliseconds / 1000).ceil();
          final double diameter = isTv ? 30 : 26;
          return SizedBox(
            width: diameter,
            height: diameter,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: 1 - clock.value,
                  strokeWidth: 2,
                  backgroundColor: HotstarPlayerStyle.trackInactive,
                  valueColor: const AlwaysStoppedAnimation(Colors.white),
                ),
                Text(
                  '$seconds',
                  // 13 sp inside a 30 dp ring: the card's *only* string
                  // under the 14 sp ten-foot floor
                  // (vlc/panel/player_panel_metrics.dart), and declared here
                  // the same way that file declares its own 13. Two digits at
                  // 14 sp measure 28 dp against 26 dp of clear space inside
                  // the stroke, and the number is redundant with the arc it
                  // sits in - the arc, not the digits, is what says the
                  // advance is coming.
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: isTv ? 13 : 11,
                    fontWeight: FontWeight.w800,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The card's two actions, in the chrome's button idiom: a [Focus] that
/// handles select/enter/space and an [InkWell] that cannot take focus itself.
///
/// The InkWell is deliberately not focusable. Left to its default it creates a
/// second focus node at the same geometry as the wrapper, and directional
/// traversal then has two indistinguishable targets per button — one of which
/// handles no keys.
///
/// No gamepad glyph on either of them. The reference badges its actions with
/// controller faces; a badge for a device that may not be attached is a lie,
/// and the card is reached by focus, not by a fixed button.
class _CardButton extends StatefulWidget {
  const _CardButton({
    required this.label,
    required this.onPressed,
    required this.filled,
    required this.isTv,
    required this.debugLabel,
    this.autofocus = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool filled;
  final bool isTv;
  final String debugLabel;
  final bool autofocus;

  @override
  State<_CardButton> createState() => _CardButtonState();
}

class _CardButtonState extends State<_CardButton> {
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
    final ring = _focused && widget.isTv;
    final Color border = ring
        ? (widget.filled ? Colors.white : HotstarPlayerStyle.accent)
        : (widget.filled ? Colors.transparent : HotstarPlayerStyle.divider);

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
            canRequestFocus: false,
            borderRadius: BorderRadius.circular(10),
            child: AnimatedContainer(
              duration: HotstarPlayerStyle.fastMotionDuration,
              constraints: const BoxConstraints(minHeight: _kActionHeight),
              // The slab spans the card, so this is clearance rather than a
              // width budget - but it is still the whole of the label's
              // budget, and [_NextEpisodeCountdownState._actions] is the
              // derivation that keeps 10 affordable.
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                // The secondary is a dark slab rather than an outline, so the
                // pair reads as two buttons of equal weight filling the card.
                color: widget.filled
                    ? HotstarPlayerStyle.accent
                    : (_focused
                          ? HotstarPlayerStyle.accent.withValues(alpha: 0.16)
                          : HotstarPlayerStyle.panelElevated),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: border, width: ring ? 2 : 1),
                boxShadow: ring
                    ? [
                        BoxShadow(
                          color: HotstarPlayerStyle.accent.withValues(
                            alpha: 0.3,
                          ),
                          blurRadius: 10,
                        ),
                      ]
                    : null,
              ),
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: widget.isTv ? 16 : 13,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The full-width still across the top of the stacked card, with the UP NEXT
/// badge floated over it.
///
/// It is 16:9 when the card has the height for it and a `BoxFit.cover` crop of
/// the same frame when it does not — see [_NextEpisodeCountdownState._stacked],
/// where the [AspectRatio] above this is the column's only [Flexible] child.
///
/// The [ClipRRect] is a leaf around the image and nothing else. Wrapped any
/// higher it would be a card-sized layer over the native video surface, which
/// is the shape controls_layer_shape_test exists to forbid.
class _Still extends StatelessWidget {
  const _Still({required this.url, required this.width, required this.badge});

  final String url;
  final double width;
  final Widget badge;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: ClipRRect(
            // The inner radius, not the card's outer one: the border is
            // painted over this, and at the outer radius the image corner sat
            // a pixel proud of the line.
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(_kInnerRadius),
            ),
            child: CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              memCacheWidth: (width * 2).round(),
              // The still is offered and failed: the box is already laid
              // out, so the on-device placeholder is the honest fill.
              errorWidget: (_, _, _) => const ThumbnailErrorPlaceholder(),
              placeholder: (_, _) =>
                  const ColoredBox(color: HotstarPlayerStyle.panelElevated),
            ),
          ),
        ),
        Positioned(left: 10, top: 10, child: badge),
      ],
    );
  }
}

/// The compact layout's thumbnail. Small enough that the placeholder is a
/// legible chip rather than a hole, so a missing still keeps the row's shape.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.url, required this.width});

  final String? url;
  final double width;

  @override
  Widget build(BuildContext context) {
    final height = width * 9 / 16;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: width,
        height: height,
        child: url?.isNotEmpty == true
            ? CachedNetworkImage(
                imageUrl: url!,
                fit: BoxFit.cover,
                memCacheWidth: (width * 2).round(),
                errorWidget: (_, _, _) => const ThumbnailErrorPlaceholder(),
                placeholder: (_, _) =>
                    const ColoredBox(color: HotstarPlayerStyle.panelElevated),
              )
            : const ThumbnailErrorPlaceholder(),
      ),
    );
  }
}
