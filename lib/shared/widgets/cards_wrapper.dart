import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../focus/app_focus.dart';

/// The focus affordance shared by every card-like surface in the app.
///
/// What Netflix and Prime Video do, because what they do works: the card grows
/// a little, takes a **thin neutral border**, and gets a shadow under it. That
/// is all.
///
/// What was here before was three accent-coloured layers at once - a 3 dp
/// `colorScheme.primary` ring, an 18 % primary wash painted *over* the poster,
/// and a primary glow behind it. Any one of them reads; all three at once
/// recolour the artwork they are supposed to be pointing at, which is why no
/// ten-foot interface of this kind uses an accent for focus. A neutral border
/// separates from every poster, because a poster can be any colour but the
/// gap between two cards is always the page.
///
/// Two layers, and both are kept in the tree in *both* states:
///  * the **border and shadow**, painted with [BorderSide.strokeAlignOutside]
///    so the stroke sits entirely outside the card. An inside border eats
///    `2 * width` from the artwork and the card visibly shrinks as it gains
///    focus;
///  * nothing over the child at all. The wash is gone.
///
/// Returning a decoration rather than `null` in the unfocused state is
/// deliberate: a null decoration makes [Container] drop its [DecoratedBox],
/// which changes the shape of the element tree on every focus change and
/// forces the whole card subtree - including the network image - to be
/// re-inflated.
class CardFocusAffordance {
  const CardFocusAffordance._();

  /// Ring thickness, in logical pixels. Painted outside the card, so it costs
  /// the artwork nothing.
  static const double ringWidth = AppFocus.ringWidth;

  /// The layer behind the child: the shadow that lifts a focused card off the
  /// page. Black, not accent - see this class's summary.
  static BoxDecoration glow({
    required BorderRadius borderRadius,
    required bool focused,
  }) {
    return BoxDecoration(
      borderRadius: borderRadius,
      boxShadow: AppFocus.shadows(focused: focused),
    );
  }

  /// The layer in front of the child: the border, and only the border.
  static BoxDecoration ring(
    BuildContext context, {
    required BorderRadius borderRadius,
    required bool focused,
  }) {
    return BoxDecoration(
      borderRadius: borderRadius,
      border: AppFocus.border(
        context,
        focused: focused,
        outside: true,
        width: ringWidth,
      ),
    );
  }
}

class CardsWrapper extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final double scaleFactor;
  final bool autoFocus;
  final BorderRadius? borderRadius;
  final FocusNode? focusNode;

  /// Called whenever this card gains or loses focus.
  ///
  /// Exists so a caller that needs its own focus state (the Continue Watching
  /// card, for one) can read it from here instead of nesting a second [Focus]
  /// node inside this one, which would add a second stop to every D-pad
  /// traversal of the rail.
  final ValueChanged<bool>? onFocusChange;

  const CardsWrapper({
    super.key,
    required this.child,
    required this.onTap,
    this.onLongPress,
    this.scaleFactor = 1.03,
    this.autoFocus = false,
    this.borderRadius,
    this.focusNode,
    this.onFocusChange,
  });

  @override
  State<CardsWrapper> createState() => _CardsWrapperState();
}

/// The scale a card that has never been focused or hovered is drawn at.
/// See the [ScaleTransition] in [_CardsWrapperState.build].
const AlwaysStoppedAnimation<double> _kNoScale =
    AlwaysStoppedAnimation<double>(1.0);

class _CardsWrapperState extends State<CardsWrapper>
    with SingleTickerProviderStateMixin {
  // Lazily-built. Hundreds of cards live offscreen in long rails and never
  // get focused or hovered — creating an AnimationController for each one
  // up front wastes vsync registrations and Tween allocations.
  AnimationController? _controller;
  Animation<double>? _scaleAnimation;
  bool _isFocused = false;
  bool _isHovered = false;
  late FocusNode _node;

  /// Whether the select/enter key is currently held down.
  bool _selectKeyDown = false;

  /// Set to true once the first KeyRepeatEvent fires (OS-level long press).
  bool _longPressTriggered = false;

  @override
  void initState() {
    super.initState();
    _node = widget.focusNode ?? FocusNode();

    if (widget.autoFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _node.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(covariant CardsWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      if (oldWidget.focusNode == null) _node.dispose();
      _node = widget.focusNode ?? FocusNode();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    if (widget.focusNode == null) {
      _node.dispose();
    } else {
      if (widget.focusNode!.hasFocus) {
        widget.focusNode!.unfocus();
      }
    }
    super.dispose();
  }

  void _ensureController() {
    if (_controller != null) return;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: widget.scaleFactor,
    ).animate(CurvedAnimation(parent: _controller!, curve: Curves.easeInOut));
  }

  void _updateAnimation() {
    // Focus grows the card whatever moved focus there. The old version stood
    // the scale down for D-pad specifically, which left the remote - the one
    // input that cannot point at anything - with the weakest cue of the three
    // on offer. A focused card is also scrolled to the middle of its rail
    // below, so there is no edge for it to overflow.
    final shouldScale = _isHovered || _isFocused;
    if (shouldScale) {
      _ensureController();
      _controller!.forward();
    } else {
      _controller?.reverse();
    }
  }

  void _onFocusChange(bool hasFocus) {
    if (!hasFocus) {
      _selectKeyDown = false;
      _longPressTriggered = false;
    }
    setState(() {
      _isFocused = hasFocus;
    });
    _updateAnimation();
    widget.onFocusChange?.call(hasFocus);
    if (hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final ro = context.findRenderObject();
        if (ro is! RenderBox || !ro.hasSize || !ro.attached) return;
        const duration = Duration(milliseconds: 380);
        const curve = Curves.fastOutSlowIn;

        // Horizontal: always center the focused card inside its row so the
        // active card stays in the middle of the screen as the user walks
        // along the row.
        Scrollable.maybeOf(
          context,
          axis: Axis.horizontal,
        )?.position.ensureVisible(
          ro,
          alignment: 0.5,
          duration: duration,
          curve: curve,
        );

        // Vertical: only scroll if the row is actually clipped. Target the
        // horizontal parent scrollable row's RenderObject to prevent
        // horizontal animation coordinate mutations from fighting with
        // vertical scrolling, which causes screen jitter/jumping.
        final vScroll = Scrollable.maybeOf(context, axis: Axis.vertical);
        if (vScroll != null && vScroll.context.mounted) {
          final scrollBox = vScroll.context.findRenderObject();
          if (scrollBox is RenderBox && scrollBox.hasSize && scrollBox.attached) {
            final hScroll = Scrollable.maybeOf(context, axis: Axis.horizontal);
            final targetContext = (hScroll != null && hScroll.context.mounted)
                ? hScroll.context
                : context;
            final targetRo = targetContext.findRenderObject();
            if (targetRo is RenderBox && targetRo.hasSize && targetRo.attached) {
              try {
                final top = targetRo
                    .localToGlobal(Offset.zero, ancestor: scrollBox)
                    .dy;
                final bottom = top + targetRo.size.height;
                final viewportH = scrollBox.size.height;
                if (top < 0 || bottom > viewportH) {
                  vScroll.position.ensureVisible(
                    targetRo,
                    alignment: 0.5,
                    duration: duration,
                    curve: curve,
                  );
                }
              } catch (_) {}
            }
          }
        }
      });
    }
  }

  void _onHover(bool isHovered) {
    setState(() {
      _isHovered = isHovered;
    });
    _updateAnimation();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      onFocusChange: _onFocusChange,
      onKeyEvent: (node, event) {
        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.space) {
          if (event is KeyDownEvent) {
            if (widget.onLongPress == null) {
              // No long-press handler — fire tap immediately.
              widget.onTap();
              return KeyEventResult.handled;
            }
            // Start tracking the press; don't fire anything yet.
            _selectKeyDown = true;
            _longPressTriggered = false;
            return KeyEventResult.handled;
          } else if (event is KeyRepeatEvent) {
            // The OS fires KeyRepeatEvent after the platform key-repeat
            // delay (~500 ms). Treat the first repeat as a long press.
            if (_selectKeyDown &&
                !_longPressTriggered &&
                widget.onLongPress != null) {
              _longPressTriggered = true;
              widget.onLongPress!();
            }
            return KeyEventResult.handled;
          } else if (event is KeyUpEvent) {
            // Short press: no repeat was received before release → tap.
            if (_selectKeyDown && !_longPressTriggered) {
              widget.onTap();
            }
            _selectKeyDown = false;
            _longPressTriggered = false;
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        onEnter: (_) => _onHover(true),
        onExit: (_) => _onHover(false),
        child: GestureDetector(
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          child: Builder(
            builder: (context) {
              // A border is for whoever is driving the app without a
              // pointer; a finger that just tapped this card does not need
              // one drawn around it afterwards.
              final showFocus = showFocusIndicator(context, _isFocused);
              final borderRadius =
                  widget.borderRadius ?? BorderRadius.circular(12);
              // A plain Container, not an AnimatedContainer: the latter builds
              // an AnimationController in initState, and a rail holds hundreds
              // of cards that are never focused at all.
              final card = Container(
                decoration: CardFocusAffordance.glow(
                  borderRadius: borderRadius,
                  focused: showFocus,
                ),
                foregroundDecoration: CardFocusAffordance.ring(
                  context,
                  borderRadius: borderRadius,
                  focused: showFocus,
                ),
                child: widget.child,
              );
              // Always a [ScaleTransition], even before the controller
              // exists. Returning the bare card until the first focus or
              // hover changes the shape of the element tree the moment either
              // arrives, and that re-inflates everything below it - including
              // the network image the card is mostly made of. A stopped
              // animation costs one Transform and no ticker.
              return ScaleTransition(
                scale: _scaleAnimation ?? _kNoScale,
                child: card,
              );
            },
          ),
        ),
      ),
    );
  }
}
