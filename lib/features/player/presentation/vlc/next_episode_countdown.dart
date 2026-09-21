import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/thumbnail_error_placeholder.dart';
import '../widgets/hotstar_player_style.dart';
import '../widgets/player_activation.dart';
import '../widgets/player_control_components.dart';
import '../../../../shared/focus/app_focus.dart';

/// The "up next" card shown in the closing seconds of an episode.
///
/// Engine-agnostic: every value it renders and both outcomes are handed in, so
/// it can be tested without a player.
///
/// Exactly one of [onPlayNext] and [onCancel] is ever called, and it is called
/// at most once — auto-advance is destructive and a double fire skips two
/// episodes. The parent unmounts the card in response to either, and must not
/// show it again for this episode after [onCancel].
///
/// Two layouts: stacked (TV, desktop, tablet), a full-width still above a panel
/// above the two actions; and compact (a phone held sideways), a thumbnail
/// beside the text. See [_kCompactWidth] for why the stacked shape does not fit
/// a phone's landscape height.
///
/// The still is the stacked column's one [Flexible] child, so the card's height
/// is bounded by construction rather than by an arithmetic budget a longer
/// string or a larger text scale could silently blow past. The layout is solved
/// on the 960x540 dp canvas a 1080p television reports, the tightest of the
/// three form factors.
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
  /// episode art — and the two layouts answer it differently.
  final String? posterUrl;

  final int? season;
  final int? episode;

  /// Out of 10, matching the catalogue's scale. Null or <= 0 hides it.
  final double? rating;

  /// Episode runtime. Anything under a minute is treated as unknown — a
  /// handful of seconds is metadata noise, not a runtime.
  final Duration? runtime;

  final String? description;

  /// How long before the advance happens on its own.
  final Duration countdown;

  /// Holds the countdown where it is. Pausing playback must not burn the timer
  /// down: the viewer who pauses at the credits is the one reading this card.
  final bool paused;

  final bool isTv;

  /// Fired by "Play now" and by the countdown reaching zero.
  final VoidCallback onPlayNext;

  /// The viewer declined. Nothing else happens — the episode plays out.
  final VoidCallback onCancel;

  @override
  State<NextEpisodeCountdown> createState() => _NextEpisodeCountdownState();
}

/// Card width on a television, derived from the longest action label.
///
/// The widest shipped locale is Kannada, whose `playNow` lays out at 224 dp at
/// the ten-foot 16 sp (`RenderParagraph.maxIntrinsicWidth`; Hindi is 144 and
/// English 128). `224 label + 2 x 10 button padding + 2 x 14 card padding` is
/// 272, rounded up to 300 for slack.
///
/// The height is not solved here: see [_available] and [_stacked], where the
/// panel takes what it needs and the still takes what is left.
const double _kTvWidth = 300;

/// Desktop and tablet, only reached when the shortest side is >= 600 dp.
/// `400 - 28 - 20` leaves 352 dp of label per action against Kannada's 182 dp
/// at 13 sp.
const double _kWideWidth = 400;

/// Compact card width, for a phone held sideways.
///
/// A landscape phone is ~390 dp tall and the stacked shape does not fit: forced
/// down that branch the panel alone wants 237 dp — its two title lines, two
/// synopsis lines and two stacked actions are width-independent — and overflows
/// before the still has taken a single dp. The compact row lays out at 218.
///
/// The width answers the same label question [_kTvWidth] does:
/// `300 - 24 - 20 = 256` dp per stacked action, against Kannada's 185.5 dp at
/// the touch 13 sp.
const double _kCompactWidth = 300;

/// The band the player's top bar occupies, which the card is held clear of.
///
/// `PlayerTopBar` lays out 0..92 dp at 960x540 and its title fills the width
/// the bottom-right card shares. One constant for all three form factors: the
/// ten-foot bar is the tallest of them, so 92 is conservative elsewhere.
///
/// Deliberately not conditional on the chrome being visible. The card can be up
/// with the bars hidden, and a card that sized itself off them would resize
/// under the viewer every time they tapped.
const double _kTopChromeHeight = 92;

/// The clearance the card holds over the scrubber.
///
/// From the shared chrome token so the card follows the bottom bar instead of
/// repeating its metrics, and per form factor because the bar is: 92 dp on a
/// handset, 102 on a desktop window and 116 on a television.
///
/// Too small a clearance is worse than it looks: the card is a later child of
/// the player's Stack than the controls, so it does not merely cover the right
/// end of the seek bar, it hit-tests in front of it and eats the drags aimed
/// at it.
///
/// One correction, and only one. The clearance is a preference and gives
/// before the card breaks: [_kMinCardHeight] is reserved out of the viewport
/// and what is left over is the clearance. [build] hands the card
/// `size.height - clearance`, so a flat clearance overflows a 360 dp-tall
/// phone by 2 dp and a 320 dp one by 34.
///
/// There used to be a second correction - `+ 48` below
/// [PlayerBottomBar.narrowTouchWidth], for the run the action strip took on a
/// portrait handset. The strip scrolls now and is one line at every width, so
/// that run does not exist and the correction was 48 dp of empty video held
/// above the bar on the one form factor with the least of it to spare.
double _bottomClearance(
  Size size,
  EdgeInsets padding, {
  required double edge,
  required bool isTv,
}) {
  final double preferred =
      HotstarPlayerStyle.bottomChromeHeightFor(isTv: isTv) + 12;
  final double room = size.height - padding.bottom - _kMinCardHeight;
  return math.min(preferred, math.max(0.0, room));
}

/// The largest text scale the card honours.
///
/// The card cannot scroll and cannot grow — it is pinned between the running
/// title and the scrubber — and honouring the full accessibility range
/// overflowed it from scale 1.6 up. 1.3 is the top of Android's Display
/// font-size setting, so every scale reachable without opening Accessibility is
/// honoured in full and the card keeps its geometry past that.
///
/// A touch and desktop rule: main.dart pins `TextScaler.noScaling` on TV.
const double _kMaxTextScale = 1.3;

/// The card's floor. The clearance over the title is only a preference, and on
/// a short enough viewport the floor wins.
///
/// A 360 dp-wide phone is 360 dp tall held sideways, leaving 124 dp for a
/// compact card that measures 218 at every scale it honours. An overlap with
/// the top bar beats a broken card, and it is least serious on that branch: the
/// touch title paints at 18 sp, and the bar's only control, Back, is at the far
/// left of a bar this right-anchored card never reaches.
///
/// It is also the reserve [_bottomClearance] hands back to the viewport, so the
/// two rules cannot fight — the clearance over the scrubber is given up a dp at
/// a time to keep this whole.
///
/// 224 rather than 218: the spare six dp are for a locale whose two-line action
/// label would push a slab past 44 dp.
const double _kMinCardHeight = 224;

class _NextEpisodeCountdownState extends State<NextEpisodeCountdown>
    with SingleTickerProviderStateMixin {
  /// One clock, not a timer plus an animation: driving the deadline off the
  /// ring's own controller means the ring cannot disagree with the moment it
  /// fires.
  late final AnimationController _clock;

  /// Latches on the first outcome so neither callback can fire twice — a
  /// second [onPlayNext] would skip an episode nobody asked to skip.
  bool _settled = false;

  /// The card's own focus scope, and the whole reason the remote can reach it.
  ///
  /// Flutter applies a pending autofocus only while the target scope has no
  /// focused child (`_Autofocus.applyIfValid` in focus_manager.dart). The card
  /// is a sibling of the controls in the player's Stack and the controls
  /// guarantee the route scope always has a focused child, so an autofocus
  /// resolved against the route scope is discarded and the remote never reaches
  /// the card. A scope of the card's own is empty by definition, so the
  /// autofocus on the Play-now button lands, and applying it makes this scope
  /// the route's focused child on the way.
  ///
  /// The post-frame [FocusScopeNode.requestFocus] in [_grabRemoteAfterFrame]
  /// covers the one case the autofocus cannot: an autofocus is discarded
  /// permanently if anything was already focused inside this scope, whereas a
  /// request is not gated on `focusedChild`. It cannot fight the autofocus — a
  /// request on a scope with no focused child only marks the scope, and the
  /// autofocus resolves it onto Play now in the same pass.
  ///
  /// The controls cannot take the focus back: their sink only reclaims when
  /// primary focus is a [FocusScopeNode] that is an ancestor of the sink, and
  /// this scope is a sibling.
  final FocusScopeNode _cardScope = FocusScopeNode(
    debugLabel: 'next-episode-card',
  );

  /// Whether the player route is the one the remote belongs to.
  ///
  /// The card is raised off a position sample, so it can mount while a panel is
  /// open over the player. The panel is a [PopupRoute], so the player route
  /// underneath stays built and focusable and both of the focus grabs below
  /// would otherwise reach across the modal: the remote would land on a control
  /// underneath the barrier and the first Back would be eaten by [_onCardKey]
  /// instead of popping the panel. Both are gated on this.
  ///
  /// `_ModalScopeStatus` is an [InheritedModel] keyed on exactly this aspect,
  /// so depending on it in [build] rebuilds the card when a route is pushed
  /// over the player or popped off it. That is what hands the remote to a card
  /// waiting behind a panel: `autofocus` flips true, `Focus.didUpdateWidget`
  /// re-arms it, and [didChangeDependencies] re-runs the scope rescue.
  bool _routeIsCurrent = true;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(vsync: this, duration: widget.countdown)
      ..addStatusListener(_onClockStatus);
    if (!widget.paused) _clock.forward();
    // Safe to schedule before the route is looked up: didChangeDependencies
    // and the first build both run before a post-frame callback does.
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

  /// See [_cardScope]. After the frame, because the scope has no parent — and
  /// so nothing to be focused within — until the first build has attached it.
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
  /// ([_bottomClearance]). Handed down as a hard `maxHeight`, so the clearances
  /// are a guarantee and the still gives instead.
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
    // isTv first, compact only as the non-TV fallback. A 1080p television
    // reports 960x540 dp, so a bare `shortestSide < 600` is true on every set
    // and would lay the ten-foot card out as a phone card floated over the
    // bottom bar it is written to clear.
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
      // scroll.
      maxScaleFactor: _kMaxTextScale,
      child: Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: EdgeInsets.only(
            // The trailing line: the bar's own right padding plus the optical
            // inset the track's far end and the last utility button both
            // answer to. See `HotstarPlayerStyle.trackEndInset`.
            right:
                (widget.isTv
                    ? edge
                    : (padding.right > edge ? padding.right : edge)) +
                HotstarPlayerStyle.trackEndInset,
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
                    // here, because the ring repaints on each vsync.
                    decoration: BoxDecoration(
                      color: HotstarPlayerStyle.panel.withValues(alpha: 0.94),
                      borderRadius: BorderRadius.circular(_kRadius),
                    ),
                    // The border paints in front of the content, which the
                    // default [DecorationPosition.background] does not: the
                    // still is flush to the card's top and both sides, so a
                    // background border is overpainted along the top edge.
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

  /// The still, then the panel, then the two actions.
  ///
  /// The still is the column's one [Flexible] child, which is the whole shape
  /// of the height contract. The panel is inflexible and lays out at whatever
  /// its text needs; the still takes what is left, capped at 16:9 by the
  /// [AspectRatio] and cropped by `BoxFit.cover` below that. So the card is
  /// bounded by the box [build] hands it, at any text scale it honours and in
  /// any locale.
  ///
  /// A missing still is not rendered as a full-width placeholder: that is a
  /// letterbox with a broken-image glyph floating in it. The badge becomes the
  /// panel's first row instead and the card gives the height back. [_Still]
  /// keeps the placeholder for the case that matters, a still that is offered
  /// and fails to load with the box already laid out.
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
                    // Explicit, so the panel's height does not depend on
                    // whichever font the platform resolves — Hindi and Kannada
                    // glyphs are taller than Latin.
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

  /// A phone held sideways: a thumbnail beside the text. See [_kCompactWidth].
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
              // At 96x54 dp a placeholder reads as a chip rather than the hole
              // the stacked layout refuses, so a missing still keeps the row.
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

  /// One line on every branch but the desktop one. On the two branches short of
  /// height a second line costs 21.6 dp out of the still on a television and
  /// out of the clearance over the scrubber on a phone.
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

  /// UP NEXT and the countdown ring, together — the ring is the only thing on
  /// screen saying the advance will happen by itself. Over a still they ride in
  /// a scrim-backed chip in its top-left corner; with no still they are the
  /// panel's first row.
  Widget _badge(AppLocalizations l10n, {required bool onStill}) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.upNext.toUpperCase(),
          // The ten-foot 14 sp costs no height: the badge is as tall as the
          // 30 dp ring, not as tall as the label.
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
      // A flat translucent fill, not a blur: this sits over the still and the
      // ring under it repaints every vsync.
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

  /// The `S1 E2` pill followed by whatever else the catalogue knows. Null when
  /// it knows nothing — a row of empty separators looks broken.
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
                // 14 is the ten-foot floor (panel/player_panel_metrics.dart),
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

    // See [_metaRow]: 14 is the ten-foot floor.
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

  /// Two actions of equal prominence, stacked, each the card's full width.
  ///
  /// Side by side each label had 97 dp on a television card, and every shipped
  /// locale ellipsised: at the ten-foot 16 sp English wants 128 dp, Hindi 144
  /// and Kannada 224. A row wide enough for Kannada needs 526 dp, over half the
  /// screen. Stacking hands each label the whole card instead — 240 dp on TV,
  /// 352 on desktop, 256 on the compact strip — for 52 dp of height that comes
  /// out of the still, and the D-pad walks Play now to Cancel with Down rather
  /// than Right.
  ///
  /// Play now stays first in the tree, so native traversal reaches it first and
  /// the autofocus lands on the outcome the timeout is about to take anyway.
  Widget _actions(AppLocalizations l10n) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CardButton(
          label: l10n.playNow,
          filled: true,
          isTv: widget.isTv,
          // Activating this is what the countdown is about to do anyway, so an
          // accidental select costs nothing. This only resolves the card's
          // scope onto a child; [_cardScope] is what brings the remote into the
          // scope at all.
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

/// Focus node labels, public so tests can assert where the remote is without
/// owning a [FocusNode]: traversal between the card's two controls stays
/// entirely native.
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

/// The gap between the two stacked actions.
const double _kActionGap = 8;

/// The minimum height a rendered action slab may report; 44 dp is the shared
/// chrome's target rule.
const double _kActionHeight = 44;

/// Ring plus remaining seconds, in its own [RepaintBoundary] because it is the
/// only part of the card that changes: without one every frame of the ring
/// would repaint the still, the text and the buttons over the video surface.
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
                  // The card's only string under the 14 sp ten-foot floor
                  // (vlc/panel/player_panel_metrics.dart): two digits at 14 sp
                  // measure 28 dp against 26 dp of clear space inside the
                  // stroke, and the arc, not the digits, is what says the
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
/// traversal then has two indistinguishable targets per button, one of which
/// handles no keys.
///
/// No gamepad glyph on either: the card is reached by focus, not by a fixed
/// button, and a badge for a device that may not be attached is a lie.
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
    // The ring is for whoever is driving the player without a pointer, on
    // every form factor - it used to be gated on `isTv`, which left a phone
    // with a hardware keyboard and a desktop window with no focus cue at all.
    final ring = showFocusIndicator(context, _focused);
    final Color border = ring
        ? HotstarPlayerStyle.focusRing
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
              // width budget. See [_NextEpisodeCountdownState._actions].
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                // The secondary is a dark slab rather than an outline, so the
                // pair reads as two buttons of equal weight filling the card.
                color: widget.filled
                    ? HotstarPlayerStyle.accent
                    : (ring
                          ? HotstarPlayerStyle.focusFill
                          : HotstarPlayerStyle.panelElevated),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: border,
                  width: ring ? HotstarPlayerStyle.focusRingWidth : 1,
                ),
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
/// badge floated over it. 16:9 when the card has the height for it and a
/// `BoxFit.cover` crop of the same frame when it does not.
///
/// The [ClipRRect] is a leaf around the image and nothing else. Wrapped any
/// higher it would be a card-sized layer over the native video surface, which
/// controls_layer_shape_test forbids.
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
            // painted over this, and at the outer radius the image corner sits
            // a pixel proud of the line.
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(_kInnerRadius),
            ),
            child: CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              memCacheWidth: (width * 2).round(),
              // The still was offered and failed: the box is already laid
              // out, so the placeholder is the honest fill.
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
