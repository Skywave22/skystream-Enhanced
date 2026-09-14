import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

/// A lazily-built panel list that opens centred on a chosen row and never
/// leaves the remote with nothing focused.
///
/// `autofocus` inside a [ListView.builder] only fires for rows the builder has
/// actually run, so a list opened far down its range leaves focus on the
/// enclosing route scope, which the panel's key sink cannot see. So the list
/// opens already scrolled near the anchor, from [estimatedRowExtent], so the
/// anchor row is built and its `autofocus` fires; it re-centres on the
/// anchor's laid-out rect after the first frame, because autofocus only
/// requests focus and only D-pad traversal scrolls; and on the second frame it
/// moves focus into the list itself if no row claimed it.
///
/// The anchor is decided once, at open. A later [anchorIndex] never scrolls or
/// refocuses, but a shrinking [itemCount] that unmounts the focused row is
/// caught and focus is put back inside the list.
class PanelAnchoredList extends StatefulWidget {
  const PanelAnchoredList({
    required this.itemCount,
    required this.itemBuilder,
    required this.anchorIndex,
    required this.estimatedRowExtent,
    this.autofocus = false,
    this.padding = const EdgeInsets.only(bottom: 12),
    super.key,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  /// Row the list should open on. Zero or negative means the top.
  final int anchorIndex;

  /// Rough height of one row, used only to seed the opening scroll offset so
  /// the anchor row is built on the first frame; the real position comes from
  /// the row's measured geometry a frame later.
  final double estimatedRowExtent;

  /// Whether this list is the one that should take focus when the panel opens.
  /// Independent of the scroll: a touch screen anchors without focusing.
  final bool autofocus;

  final EdgeInsetsGeometry padding;

  @override
  State<PanelAnchoredList> createState() => _PanelAnchoredListState();
}

class _PanelAnchoredListState extends State<PanelAnchoredList> {
  /// Viewport alignment for the anchor row: dead centre.
  static const double _kAnchorAlignment = 0.5;

  /// The anchor as it was when the list opened. Read once: moving [_anchorKey]
  /// to another row would carry the old row's element, and its focus, with it.
  late final int _anchor = widget.anchorIndex;

  late final ScrollController _controller = ScrollController(
    initialScrollOffset: _anchor > 0 ? _anchor * widget.estimatedRowExtent : 0,
  );

  /// Marks the anchor row so its laid-out rect can be read after frame one.
  final GlobalKey _anchorKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Frame one: the anchor row has geometry but nothing holds focus yet, so
      // the jump cannot move focus. A zero-duration ensureVisible keeps the
      // anchor mounted and its pending autofocus valid.
      _centreAnchor();
      if (widget.autofocus) {
        // Frame two, not one: the frame that mounted the rows still sees an
        // empty scope and would steal focus from the anchor onto row zero.
        WidgetsBinding.instance.addPostFrameCallback((_) => _rescueFocus());
      }
    });
  }

  @override
  void didUpdateWidget(PanelAnchoredList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A changed anchorIndex is ignored: the anchor is an open-time decision.
    // A list that shrank may be about to unmount the focused row, dropping
    // focus to the root scope, where no key reaches the panel.
    if (widget.itemCount < oldWidget.itemCount && _ownsPrimaryFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _rescueFocus());
    }
  }

  /// Whether the node holding primary focus is one of this list's rows.
  bool get _ownsPrimaryFocus {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) return false;
    return focused.findAncestorStateOfType<_PanelAnchoredListState>() == this;
  }

  /// Puts the anchor row mid-viewport using its laid-out size, correcting the
  /// estimate the opening offset was seeded from.
  ///
  /// [ScrollPosition.ensureVisible] clamps to the scroll extents, so a short
  /// list or an anchor near an end pins to that edge instead of overscrolling
  /// and springing back.
  void _centreAnchor() {
    if (!mounted || _anchor <= 0) return;
    final anchor = _anchorKey.currentContext;
    // The estimate missed by more than a viewport plus the cache: keep the
    // seed; the focus rescue still runs.
    if (anchor == null) return;
    Scrollable.ensureVisible(
      anchor,
      alignment: _kAnchorAlignment,
      duration: Duration.zero,
    );
  }

  /// Puts focus in the list if nothing in the panel's scope holds it.
  ///
  /// Reached when the seeded offset missed the anchor and when a shrinking
  /// list unmounted the focused row. In both cases focus sits on the enclosing
  /// scope or on the root, and neither can see a key. Focus that is genuinely
  /// somewhere else, such as a sheet pushed over the panel, is left alone.
  ///
  /// The row chosen is the one nearest the middle of the viewport, and it is
  /// brought fully on screen: directional traversal from an empty scope picks
  /// the topmost focusable node, which is a tab button or a row well above the
  /// fold.
  void _rescueFocus() {
    if (!mounted) return;
    final scope = FocusScope.of(context);
    // A row or a tab holds it: nothing to do.
    if (scope.hasFocus && !scope.hasPrimaryFocus) return;
    final primary = FocusManager.instance.primaryFocus;
    if (primary != null &&
        primary != scope &&
        primary != FocusManager.instance.rootScope) {
      return;
    }
    // The scope remembers the row focused before the one that vanished.
    final remembered = scope.focusedChild;
    final target = remembered != null && _isRowOfThisList(remembered)
        ? remembered
        : _rowNearestCentre(scope);
    if (target == null) {
      scope.focusInDirection(TraversalDirection.down);
      return;
    }
    target.requestFocus();
    final rowContext = target.context;
    if (rowContext != null) {
      Scrollable.ensureVisible(
        rowContext,
        alignment: _kAnchorAlignment,
        duration: Duration.zero,
      );
    }
  }

  bool _isRowOfThisList(FocusNode node) {
    final rowContext = node.context;
    return node.canRequestFocus &&
        rowContext != null &&
        rowContext.findAncestorStateOfType<_PanelAnchoredListState>() == this;
  }

  /// The focusable row of this list whose centre is nearest the viewport's.
  FocusNode? _rowNearestCentre(FocusScopeNode scope) {
    final viewport = context.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return null;
    final centre = viewport.localToGlobal(viewport.size.center(Offset.zero)).dy;
    FocusNode? best;
    var bestDistance = double.infinity;
    for (final node in scope.traversalDescendants) {
      if (!_isRowOfThisList(node)) continue;
      final distance = (node.rect.center.dy - centre).abs();
      if (distance < bestDistance) {
        best = node;
        bestDistance = distance;
      }
    }
    return best;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _controller,
      padding: widget.padding,
      // A D-pad can only focus a row that exists, and the default 250px runs
      // out two rows below the fold.
      scrollCacheExtent: const ScrollCacheExtent.pixels(800),
      itemCount: widget.itemCount,
      itemBuilder: (context, index) {
        final row = widget.itemBuilder(context, index);
        if (index != _anchor) return row;
        return KeyedSubtree(key: _anchorKey, child: row);
      },
    );
  }
}
