import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../shared/widgets/custom_widgets.dart';
import 'hotstar_player_style.dart';
import 'player_activation.dart';

/// Top zone: back button + title/subtitle. Paints its own top scrim so the
/// chrome no longer needs a separate fixed-height Positioned gradient.
class PlayerTopBar extends StatelessWidget {
  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final bool isTv;
  final FocusNode? backFocusNode;

  const PlayerTopBar({
    super.key,
    required this.title,
    this.subtitle,
    this.onBack,
    this.isTv = false,
    this.backFocusNode,
  });

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.viewPaddingOf(context);
    final edge = isTv
        ? HotstarPlayerStyle.tvEdgeInset
        : HotstarPlayerStyle.edgeInset;
    final double leftPadding = isTv
        ? edge
        : (padding.left > edge ? padding.left : edge);
    final double rightPadding = isTv
        ? edge
        : (padding.right > edge ? padding.right : edge);
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: HotstarPlayerStyle.topGradient),
      child: SafeArea(
        left: false,
        right: false,
        bottom: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(leftPadding, 14, rightPadding, 24),
          child: Row(
            children: [
              PlayerIconButton(
                icon: Icons.arrow_back_rounded,
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: onBack,
                isTv: isTv,
                focusNode: backFocusNode,
                iconSize: isTv ? 34 : 30,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Text(
                        subtitle!,
                        style: const TextStyle(
                          color: HotstarPlayerStyle.secondaryText,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    Text(
                      title,
                      style: TextStyle(
                        color: HotstarPlayerStyle.primaryText,
                        fontSize: isTv ? 22 : 18,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom zone shell: scrubber row on top, then a single flat controls row —
/// [leading] (playback) pinned left and [actions] (everything else) filling
/// the rest, right-anchored.
///
/// THE OVERFLOW CONTRACT. A control row that can only lay out is a row nobody
/// dares add a button to: the last attempt to render the volume button
/// everywhere overflowed the non-touch row by 12 dp and was "solved" by hiding
/// the control on four platforms. So neither branch below may ever overflow,
/// and neither may hide a button:
///
///   * Off touch the actions are a [Wrap]. When they fit it is one
///     right-aligned run, byte-for-byte the layout the old `Spacer()` produced;
///     when they do not, the extras take a second run *above* the first and
///     the bar grows upwards. Nothing is clipped, so nothing needs a scroll
///     affordance, and both a D-pad (Up/Down across the runs, Left/Right along
///     one) and a pointer reach every button with no gesture at all.
///   * On touch they are a right-anchored finger-scroll strip with a visible
///     edge hint, because a landscape handset has room for most of the row
///     and a five-run bar would swallow the film. Every button is still
///     present and reachable - by the one input that can fling a strip.
///   * On touch AND below [narrowTouchWidth], the strip gets a *run of its
///     own*, above the transport row, whenever the two cannot share one.
///     This is not decoration. [leading] is five pinned buttons - seek back,
///     play/pause, seek forward, lock, next - and they measure 250 dp; a
///     360 dp portrait handset has 320 dp inside its edge insets, so sharing
///     one row leaves the strip **70 dp**, which is one button of ten plus a
///     28 dp edge hint painted over the next. That is not a strip, it is a
///     chevron. Given the whole width the same strip shows six of the ten and
///     scrolls honestly to the rest, and the bar grows by exactly one run -
///     the same trade the [Wrap] above already makes off touch.
///
/// The reflow is content-driven rather than counted: [Wrap] puts the two on
/// one run when they genuinely fit and on two when they do not. A bar stripped
/// down by the viewer's settings - one utility at 360 dp of inner width, two
/// at 412 - keeps the flat single line and pays no height for a rule it does
/// not need. When the split does happen and the utilities still do not need
/// the whole line, they sit at its left under the transport row rather than
/// hard right: nothing is hidden there, so there is nothing for the
/// right-anchoring to protect.
///
/// That is the whole of the fork, and it is a layout ramp rather than a
/// capability gate: every branch renders the *same* button list.
///
/// Left/Right/Up/Down are left to [DirectionalFocusAction]: the buttons are
/// siblings in one [Row] inside one [FocusTraversalGroup], so geometric
/// traversal already walks the row and stops at its ends. An earlier version
/// drove Left/Right by hand with [FocusNode.nextFocus]/[previousFocus]; those
/// operate on the enclosing *scope* (the route), not the group, and wrap to
/// the route's first/last node — so Right from the last button landed somewhere
/// else on screen. Paints its own scrim.
class PlayerBottomBar extends StatelessWidget {
  final Widget progressBar;
  final List<Widget> leading;
  final List<Widget> actions;
  final bool isTv;

  /// Whether the [actions] scroll rather than wrap. See the class comment: it
  /// picks a layout for the viewport, never which controls exist.
  final bool isTouch;

  /// The widest viewport still laid out as a portrait handset, in the logical
  /// pixels the bar's own [Padding] leaves it - so a device figure minus the
  /// two [HotstarPlayerStyle.edgeInset]s.
  ///
  /// Above it the transport row and the strip always share one line, because
  /// there the strip's share is a usable five buttons or more and a second
  /// run would cost 48 dp of a 360 dp-tall landscape frame for nothing. Below
  /// it the two are allowed to split. The number sits in the gap between the
  /// widest handset held upright (430 dp on the largest iPhone, 412 on the
  /// largest Pixel) and the narrowest one turned sideways (568 dp), so no
  /// device straddles it and the split is a portrait behaviour only.
  static const double narrowTouchWidth = 520;

  const PlayerBottomBar({
    super.key,
    required this.progressBar,
    this.leading = const [],
    this.actions = const [],
    this.isTv = false,
    this.isTouch = false,
  });

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.viewPaddingOf(context);
    final edge = isTv
        ? HotstarPlayerStyle.tvEdgeInset
        : HotstarPlayerStyle.edgeInset;
    final double leftPadding = isTv
        ? edge
        : (padding.left > edge ? padding.left : edge);
    final double rightPadding = isTv
        ? edge
        : (padding.right > edge ? padding.right : edge);
    // The same shape as the top bar's scrim: a gradient is paint, not a
    // compositing layer, so it costs nothing over the platform view and stays
    // inside the bar's own fade. Without it every reveal on a bright scene
    // puts white glyphs on white.
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: HotstarPlayerStyle.bottomGradient,
      ),
      child: SafeArea(
        left: false,
        right: false,
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(leftPadding, 2, rightPadding, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              progressBar,
              FocusTraversalGroup(child: _controlsRow()),
            ],
          ),
        ),
      ),
    );
  }

  /// The one flat control line, or - on a narrow touch viewport that cannot
  /// hold one - the transport row with the strip on a run of its own above it.
  ///
  /// The left group (seek back, play/pause, seek forward, lock, next) is
  /// always visible, never scrolled and never wrapped *within itself*; what
  /// the narrow branch moves is the strip, not a button out of the group.
  Widget _controlsRow() {
    // Sized to its own children rather than spread into the outer Row, so the
    // narrow branch can treat the whole group as one indivisible [Wrap] child.
    // Inflexible either way, so the wide branch lays out exactly as the spread
    // did.
    final Widget transport = Row(
      mainAxisSize: MainAxisSize.min,
      children: leading,
    );

    if (!isTouch) {
      return Row(
        children: [
          transport,
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.end,
              runAlignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: actions,
            ),
          ),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= narrowTouchWidth) {
          return Row(
            children: [
              transport,
              Expanded(child: PlayerActionStrip(actions: actions)),
            ],
          );
        }
        // Tight, not the Wrap's own content width: [WrapAlignment.spaceBetween]
        // has free space to give the strip only if the Wrap fills the line, and
        // without it a one-run bar would centre transport+strip as a block
        // instead of pinning them to the two edges.
        return SizedBox(
          width: double.infinity,
          child: Wrap(
            // One run: transport hard left, strip hard right - the flat bar,
            // unchanged. Two runs: each is alone on its line, so this only
            // decides that the strip starts at the left edge of its own.
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            // Runs bottom-up, so the transport row keeps the bottom line it
            // has always had and the strip appears *above* it. The other way
            // round, every reflow would shove play/pause 48 dp up the screen.
            verticalDirection: VerticalDirection.up,
            children: [
              transport,
              // Bare, so the Wrap sees the strip's content width and can put
              // it beside the transport whenever it genuinely fits. Given a
              // run to itself it takes the full line.
              PlayerActionStrip(actions: actions),
            ],
          ),
        );
      },
    );
  }
}

/// The touch action strip: right-anchored, finger-scrollable, and — this is
/// the part that was missing — visibly scrollable.
///
/// Right-anchored means the overflow slides off the **left** edge, so the
/// buttons at the end of the list are the ones that survive a squeeze and the
/// ones at the start are the ones that vanish. With no fade, no chevron and no
/// bounce at rest there was nothing on screen that said so: measured on a
/// 360 dp portrait phone, a torrent series leaves this 70 dp of the bar's
/// 320 - one button of ten - and even given the whole line by
/// [PlayerBottomBar.narrowTouchWidth] it still shows six of them, so the rest
/// simply were not there as far as the viewer could tell.
///
/// So when — and only when — content is hidden to the left, a scrim-to-clear
/// gradient with a chevron in it is painted over that edge. It is
/// [IgnorePointer]: it is a hint, not a control, and it must never eat the tap
/// meant for the half-visible button underneath it.
class PlayerActionStrip extends StatefulWidget {
  const PlayerActionStrip({super.key, required this.actions});

  final List<Widget> actions;

  /// Width of the painted edge hint. Also the amount of the outermost button
  /// it covers, which is why it is narrow and translucent rather than opaque.
  static const double hintWidth = 28;

  @override
  State<PlayerActionStrip> createState() => _PlayerActionStripState();
}

class _PlayerActionStripState extends State<PlayerActionStrip> {
  /// Whether anything is still hidden off the left edge.
  bool _more = false;

  /// Both notifications are listened to on purpose. [ScrollNotification]
  /// covers a finger moving the strip; [ScrollMetricsNotification] covers the
  /// cases where nothing scrolled but the answer changed anyway — first
  /// layout, a rotation, a button appearing or disappearing. Metrics arrive in
  /// a microtask after layout (ScrollPosition.didUpdateScrollMetrics), so
  /// setState from here is a legal frame request rather than a build-time
  /// mutation.
  bool _update(ScrollMetrics metrics) {
    // Half a logical pixel: less than that is hidden by rounding rather than
    // by the viewport, and a hint painted for it would never go away.
    final bool more = metrics.maxScrollExtent - metrics.pixels > 0.5;
    if (more != _more && mounted) setState(() => _more = more);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) => _update(n.metrics),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) => _update(n.metrics),
        child: Stack(
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: widget.actions,
              ),
            ),
            if (_more)
              const Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: SizedBox(
                    width: PlayerActionStrip.hintWidth,
                    // Paint, not a layer: a gradient in a DecoratedBox costs
                    // nothing over the platform view, where an opacity or a
                    // blur would be one more IOSurface. See
                    // controls_layer_shape_test.dart.
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [Color(0xCC000000), Color(0x00000000)],
                        ),
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Icon(
                          Icons.chevron_left_rounded,
                          size: 20,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Compact icon-only button for utilities (resize, PiP, fullscreen) and the
/// top-bar back button.
///
/// THE ACCESSIBLE NAME IS EXPLICIT, AND IT HAS TO BE. A [Tooltip] wrapped
/// *around* a button does not name it: [Tooltip] annotates with
/// `SemanticsProperties.tooltip` only, and [CustomButton]'s [TextButton]
/// starts a semantics *container* underneath, so the annotation cannot merge
/// down onto the node that owns the tap. Measured before this was fixed, with
/// a real semantics dump of three of these in a row:
///
///     id=4 rect=48x48 label="" tooltip="Rewind 5 seconds" btn=false actions=[]
///       id=5 rect=48x48 label="" tooltip=""               btn=true  actions=[tap|focus]
///
/// The reader focuses the inner node — the one with the action — and finds it
/// nameless, so every player control announced as an anonymous "button".
/// Material's own [IconButton] escapes this by mounting its [Tooltip] *below*
/// the button's [Semantics], where it merges up into a single node.
///
/// The shape here does the same thing the other way round: an explicit
/// [Semantics] supplies the name and a [MergeSemantics] collapses name, button
/// flag and tap action into one node, so both TalkBack and VoiceOver focus a
/// single, named, activatable element. Asserted by
/// `test/features/player/player_semantics_test.dart`.
class PlayerIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool isTv;
  final bool highlight;
  final FocusNode? focusNode;

  /// {@macro flutter.widgets.Focus.autofocus}
  final bool autofocus;

  /// Optional icon-size override (the tap target grows to match). Used by the
  /// top-bar back button so it reads at the same weight as the title.
  final double? iconSize;

  const PlayerIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.isTv = false,
    this.highlight = false,
    this.focusNode,
    this.autofocus = false,
    this.iconSize,
  });

  @override
  State<PlayerIconButton> createState() => _PlayerIconButtonState();
}

class _PlayerIconButtonState extends State<PlayerIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final double glyph = widget.iconSize ?? (widget.isTv ? 28 : 26);
    final double box = glyph + (widget.isTv ? 20 : 18);

    Color iconColor;
    if (_hovered) {
      iconColor = HotstarPlayerStyle.accent;
    } else if (widget.highlight) {
      iconColor = HotstarPlayerStyle.accent;
    } else {
      iconColor = Colors.white;
    }

    return MergeSemantics(
      child: Semantics(
        button: true,
        label: widget.tooltip,
        child: Tooltip(
          message: widget.tooltip,
          // The button's declared box IS its footprint.
          //
          // [CustomButton] renders a Material 3 [TextButton], which brings
          // `minimumSize: Size(64, 40)` and 12 dp of padding on each side that
          // nothing here asked for. Those 24 dp are what made this row a layout
          // crisis: at 960 dp television metrics a fully loaded bar spent 24 dp
          // per button on empty space it did not have, and the answer last time
          // was to delete the volume button on four platforms rather than
          // reclaim it. Zeroing them costs no touch target - the tap target is
          // still padded to [kMinInteractiveDimension] by the button's own
          // `_InputPadding` - and buys back 24 dp x 13 buttons.
          child: TextButtonTheme(
            data: TextButtonThemeData(
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
              ),
            ),
            child: MouseRegion(
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: CustomButton(
                onPressed: widget.onPressed,
                showFocusHighlight: widget.isTv,
                focusNode: widget.focusNode,
                autofocus: widget.autofocus,
                shape: const CircleBorder(),
                child: SizedBox(
                  width: box,
                  height: box,
                  child: Icon(widget.icon, color: iconColor, size: glyph),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The big centred play/pause a phone or tablet expects over the video.
///
/// Sits beside [PlayerIconButton] so the two stay one design: same white
/// glyph, same rounded Material icons, and the disc is the only thing the
/// bottom-bar copy does not have. It is a second control, not a replacement -
/// the bar keeps its own play/pause, because the chrome's focus machinery
/// names that node and both Netflix and Prime ship two on a tablet.
///
/// Deliberately **not** a [CustomButton] and deliberately **not** a [Focus]:
/// it holds no [FocusNode], so it is not a traversal candidate and can never
/// compete for the autofocus the bottom bar's play/pause owns on television.
/// It is built on touch only, so on a remote it does not exist at all.
///
/// [HitTestBehavior.translucent] is load-bearing rather than a default. The
/// player's screen-wide gesture detector is the *first* child of the same
/// Stack and this glyph is a later one, so hit testing reaches the glyph
/// first. Opaque would stop [RenderStack.defaultHitTestChildren] dead and the
/// screen-wide detector would never enter the gesture arena - which kills
/// swipe-to-seek and swipe-for-volume started from the dead centre of the
/// frame. Translucent puts both in the arena: a tap goes to the deeper member
/// and a drag to the parent as soon as the pointer moves.
///
/// Translucent alone is not enough, and this is the part that is easy to get
/// wrong. `RenderProxyBoxWithHitTestBehavior.hitTest` returns `hitTarget`,
/// which is true whenever a *child* was hit - and `RenderParagraph.hitTestSelf`
/// returns true unconditionally, so the [Icon] in the middle of the disc makes
/// the detector answer "hit" and the Stack stops walking exactly as if it were
/// opaque. Measured: a `dragFrom(centre)` stopped seeking. So the disc is
/// wrapped in an [IgnorePointer] - it is paint, and the gesture belongs to the
/// square around it. The detector then reports no hit, adds itself to the
/// result anyway (that is what translucent means) and the walk carries on down
/// to the screen-wide detector.
///
/// The label is passed in rather than looked up here: this file is not a
/// localization boundary, and `lib/features/player/**` has a zero budget for
/// hardcoded user-visible strings.
class PlayerCenterPlayButton extends StatelessWidget {
  /// Whether playback is running - a rebuffer counts as running, exactly as it
  /// does for the bottom bar, since the film resumes without a press.
  final bool playing;

  /// The localized "Play"/"Pause" the semantics layer announces.
  final String label;

  final VoidCallback onPressed;

  const PlayerCenterPlayButton({
    super.key,
    required this.playing,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // A phone gets the smaller disc; anything with a 600 dp short side is a
    // tablet held further away and takes the larger one.
    final double diameter = MediaQuery.sizeOf(context).shortestSide < 600
        ? 72
        : 88;
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: onPressed,
        child: IgnorePointer(
          child: SizedBox.square(
            dimension: diameter,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                // A paint, not a layer: no opacity or filter here, so nothing
                // new is composited over the platform view.
                color: Colors.black.withValues(alpha: 0.34),
              ),
              // 0.52 is the Netflix/Prime proportion - a glyph inside a disc.
              // Filling the disc reads as a bare icon with a smudge behind it.
              child: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: Colors.white,
                size: diameter * 0.52,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Labelled icon button for the controls row (Sources, Subtitles, Speed, …)
/// and for the Skip Intro/Outro chip. Activates on tap and, when focused, on
/// every key [isPlayerActivation] names — select, enter, space and a game
/// controller's A; directional navigation between buttons is handled natively
/// by the enclosing traversal group — this widget never moves focus itself.
class PlayerActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool highlight;
  final bool isTv;
  final FocusNode? focusNode;

  /// {@macro flutter.widgets.Focus.autofocus}
  final bool autofocus;

  const PlayerActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.highlight = false,
    this.isTv = false,
    this.focusNode,
    this.autofocus = false,
  });

  @override
  State<PlayerActionButton> createState() => _PlayerActionButtonState();
}

class _PlayerActionButtonState extends State<PlayerActionButton> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    // The ten-foot ramp, and the reason it exists: the only two chips in the
    // player are Skip Intro/Outro and Unlock, and the skip chip is the one
    // control in the whole player on a clock. A 12 dp label with a 20 dp glyph
    // is a squint from a sofa, so the band is missed rather than skipped.
    // Same shape, bigger numbers - not a capability branch, the same
    // ergonomic ramp player_panel_metrics.dart applies, and above the 14 sp
    // floor that file documents.
    final double glyph = widget.isTv ? 26 : 20;
    final double labelSize = widget.isTv ? 18 : 12;
    final double minHeight = widget.isTv ? 52 : 44;
    final double horizontalPad = widget.isTv ? 16 : 12;

    final showBg = (widget.highlight || _focused || _pressed) && !_hovered;
    final color = (widget.highlight || _hovered || _focused || _pressed)
        ? HotstarPlayerStyle.accent
        : Colors.white;
    final showTvFocusRing = widget.isTv && _focused;

    // [MergeSemantics], for the same reason [PlayerIconButton] carries one.
    // Without it this button dumps as *two* nodes — the annotation above owns
    // the name and the button flag, the [InkWell] below owns the tap:
    //
    //     id=4 label="Subtitles" btn=true  actions=[focus]
    //       id=5 label="Subtitles" btn=false actions=[tap|focus]
    //
    // so a reader stops on the row twice and says the name twice, and the stop
    // that can actually be activated is not the one flagged as a button. The
    // label happened to reach the inner node only because the visible [Text]
    // below repeats it, which is luck rather than design: the icon-only
    // sibling had no such text and was silent. Merging collapses both into one
    // named, activatable node.
    return MergeSemantics(
      child: Semantics(
        button: true,
        selected: widget.highlight,
        label: widget.label,
        child: Focus(
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          onFocusChange: (value) => setState(() => _focused = value),
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            if (isPlayerActivation(event.logicalKey)) {
              widget.onTap();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() {
              _hovered = false;
              _pressed = false;
            }),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                onTap: widget.onTap,
                onHighlightChanged: _setPressed,
                borderRadius: BorderRadius.circular(8),
                hoverColor: Colors.transparent,
                focusColor: Colors.transparent,
                splashColor: Colors.transparent,
                highlightColor: Colors.transparent,
                child: AnimatedContainer(
                  duration: HotstarPlayerStyle.fastMotionDuration,
                  constraints: BoxConstraints(minHeight: minHeight),
                  padding: EdgeInsets.symmetric(horizontal: horizontalPad),
                  decoration: BoxDecoration(
                    color: showBg
                        ? HotstarPlayerStyle.accent.withValues(alpha: 0.16)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: showTvFocusRing
                        ? Border.all(color: HotstarPlayerStyle.accent, width: 2)
                        : null,
                    boxShadow: showTvFocusRing
                        ? [
                            BoxShadow(
                              color: HotstarPlayerStyle.accent.withValues(
                                alpha: 0.2,
                              ),
                              blurRadius: 8,
                            ),
                          ]
                        : null,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(widget.icon, color: color, size: glyph),
                      const SizedBox(width: 6),
                      // Excluded, not because the text is decorative, but
                      // because the [Semantics] above already carries this
                      // exact string: once the subtree merges, an included
                      // Text makes the node read "Subtitles\nSubtitles" and a
                      // reader says the name twice.
                      ExcludeSemantics(
                        child: Text(
                          widget.label,
                          style: TextStyle(
                            color: color,
                            fontSize: labelSize,
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
