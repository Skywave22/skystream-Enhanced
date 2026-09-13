import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The focus affordance shared by every card-like surface in the app.
///
/// This is the same recipe the player already draws for its own TV controls
/// (`player_control_components.dart`: accent ring + accent tint + soft accent
/// glow), re-expressed against [ColorScheme] instead of the player's private
/// style constants so it themes with the rest of the app.
///
/// Three layers, because one of them alone is not legible on top of a bright
/// poster on a television:
///  * a **ring**, painted with [BorderSide.strokeAlignOutside] so it sits
///    entirely OUTSIDE the card. An inside border eats
///    `2 * width` from the artwork, so the card visibly shrinks the moment it
///    gains focus;
///  * a **tint**, painted in FRONT of the child so it survives a full-bleed
///    poster (a background fill is invisible behind opaque artwork);
///  * a **glow**, painted BEHIND the child so it only reads outside the card.
///    Its blur is deliberately short-range: horizontal rails clip their
///    viewport at 8 dp of vertical padding, so a wider halo would be cut off
///    with a hard edge.
class CardFocusAffordance {
  const CardFocusAffordance._();

  /// Ring thickness, in logical pixels. Painted outside the card, so it costs
  /// the artwork nothing.
  static const double ringWidth = 3;

  /// Alpha of the accent wash drawn over the child.
  static const double tintOpacity = 0.18;

  /// Alpha of the glow drawn behind the card.
  static const double glowOpacity = 0.35;

  /// Blur of the glow. Kept within the 8 dp of vertical padding the rails give
  /// their viewports so the halo is never clipped mid-gradient.
  static const double glowBlurRadius = 8;

  /// Background layer (behind the child): the glow.
  ///
  /// Returns a decoration in both states rather than `null` when unfocused, on
  /// purpose. A `null` decoration makes [Container] drop its `DecoratedBox`
  /// altogether, which changes the shape of the element tree on every focus
  /// change and forces the whole card subtree — including the network image —
  /// to be re-inflated.
  static BoxDecoration glow({
    required BorderRadius borderRadius,
    required Color accent,
    required bool focused,
  }) {
    return BoxDecoration(
      borderRadius: borderRadius,
      boxShadow: focused
          ? <BoxShadow>[
              BoxShadow(
                color: accent.withValues(alpha: glowOpacity),
                blurRadius: glowBlurRadius,
              ),
            ]
          : null,
    );
  }

  /// Foreground layer (in front of the child): the ring and the tint.
  static BoxDecoration ring({
    required BorderRadius borderRadius,
    required Color accent,
    required bool focused,
  }) {
    return BoxDecoration(
      borderRadius: borderRadius,
      color: focused ? accent.withValues(alpha: tintOpacity) : null,
      border: focused
          ? Border.all(
              color: accent,
              width: ringWidth,
              strokeAlign: BorderSide.strokeAlignOutside,
            )
          : null,
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
    // In D-pad/keyboard mode the ring+tint+glow is the focus indicator; skip
    // scale to prevent edge items from overflowing the viewport.
    final isDpad =
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final shouldScale = _isHovered || (_isFocused && !isDpad);
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
              // Only in D-pad/keyboard/pointer-focus mode: in touch mode
              // Flutter suppresses focus highlights entirely.
              final showFocus =
                  _isFocused &&
                  FocusManager.instance.highlightMode ==
                      FocusHighlightMode.traditional;
              final borderRadius =
                  widget.borderRadius ?? BorderRadius.circular(12);
              final accent = Theme.of(context).colorScheme.primary;
              // A plain Container, not an AnimatedContainer: the latter builds
              // an AnimationController in initState, and a rail holds hundreds
              // of cards that are never focused at all.
              final card = Container(
                decoration: CardFocusAffordance.glow(
                  borderRadius: borderRadius,
                  accent: accent,
                  focused: showFocus,
                ),
                foregroundDecoration: CardFocusAffordance.ring(
                  borderRadius: borderRadius,
                  accent: accent,
                  focused: showFocus,
                ),
                child: widget.child,
              );
              final animation = _scaleAnimation;
              if (animation == null) return card;
              return ScaleTransition(scale: animation, child: card);
            },
          ),
        ),
      ),
    );
  }
}
