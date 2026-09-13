import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../core/network/link_probe_service.dart';
import '../../player/presentation/widgets/hotstar_player_style.dart';

/// Accent shared with the player chrome, so a source card's Play button and
/// the controls it launches read as one product. Both sheets use this instead
/// of re-declaring the literal.
const Color sourceSheetAccent = HotstarPlayerStyle.accent;

/// Why a sources sheet was opened. Both actions stay on every row; the mode
/// only decides the default tap action and the initial filtering.
enum SourcesMode { play, download }

/// Small coloured pill used for quality/source tags.
class SourceTag extends StatelessWidget {
  final String text;
  final Color color;
  const SourceTag({super.key, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: color,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// The frosted-glass colour set both source sheets are painted with.
///
/// A sheet paints its own glass instead of sitting on a themed [Material], so
/// nothing underneath it resolves `onSurface` for the content on top. The dark
/// values are the literals the glass design ships with; the light ones keep
/// every alpha and only flip the ink, so the panel stays legible over a bright
/// backdrop without changing shape.
///
/// It used to be a private `_GlassPalette` declared twice, once per sheet, and
/// the two copies had drifted: in light mode the Nuvio sheet used an 85%-opaque
/// warm-white pane and a 50%-black drop shadow while the Stremio sheet used a
/// 65%-opaque cool-white pane and an 18% shadow, and the focused Play chip was
/// a dark fill with light content on one and a white fill with accent content
/// on the other. A user with a scraper *and* an add-on installed - the intended
/// configuration - meets both sheets in one session, and on a television the
/// focus treatment is the cursor, so the divergence was not only cosmetic.
class GlassPalette {
  const GlassPalette._({
    required this.pane,
    required this.paneShadow,
    required this.ink,
    required this.cardFocusFill,
    required this.raisedFill,
    required this.raisedBorder,
  });

  /// Backdrop tint painted behind the blur.
  final Color pane;

  /// Drop shadow under the whole panel.
  final Color paneShadow;

  /// Text, icons and hairlines drawn on the glass. Callers dial it down with
  /// `withValues(alpha:)` rather than reaching for another literal.
  final Color ink;

  /// Fill behind the focused source card.
  final Color cardFocusFill;

  /// Fill and border of an action chip lifted out of the accent, i.e. the
  /// focused or hovered Play button.
  final Color raisedFill;
  final Color raisedBorder;

  /// Content sitting on a solid [sourceSheetAccent] fill. The accent is
  /// saturated enough to carry white in either brightness.
  Color get onAccent => Colors.white;

  /// [ink] at [alpha]. Every overlay fill and hairline on the glass is the
  /// ink at some alpha, so this saves the call sites reaching for a literal.
  Color tint(double alpha) => ink.withValues(alpha: alpha);

  static const _dark = GlassPalette._(
    pane: Color(0xA6060608), // Frosted glass obsidian tint (65% opacity)
    paneShadow: Color(0x80000000),
    ink: Colors.white,
    cardFocusFill: Color(0xFF242430),
    raisedFill: Colors.white,
    raisedBorder: Colors.white,
  );

  static const _light = GlassPalette._(
    pane: Color(0xA6F4F4F7),
    paneShadow: Color(0x2E000000),
    ink: Color(0xFF16161C),
    cardFocusFill: Color(0xFFE6E6EE),
    raisedFill: Colors.white,
    // A white chip on a pale pane needs the accent to draw its own edge.
    raisedBorder: sourceSheetAccent,
  );

  static GlassPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? _dark : _light;
}

/// Resolution pill on a source row. Shared: it was byte-identical in the two
/// sheets.
class QualityBadge extends StatelessWidget {
  final String resolution;

  const QualityBadge({super.key, required this.resolution});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final res = resolution.toUpperCase();

    Color accentColor;
    if (res.contains('4K') || res.contains('2160') || res.contains('UHD')) {
      accentColor = const Color(0xFFFFB800);
    } else if (res.contains('1080')) {
      accentColor = const Color(0xFF38BDF8);
    } else if (res.contains('720')) {
      accentColor = const Color(0xFF34D399);
    } else {
      accentColor = cs.primary;
    }

    return Container(
      constraints: const BoxConstraints(maxWidth: 80),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: accentColor.withValues(alpha: 0.4),
          width: 0.8,
        ),
      ),
      child: Text(
        resolution,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w900,
          color: accentColor,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// The Play / Download chip on a source row.
///
/// One focus stop, with arrow keys answered on its own node - see
/// [SourceCardActions] for how the card lets its chips into traversal.
class DpadSourceButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final String? tooltip;
  final VoidCallback? onPressed;
  final bool isPrimary;
  final FocusNode? focusNode;

  /// Arrow keys the chip answers itself. Handled on the chip's own node rather
  /// than in a wrapping [Focus] so it keeps contributing exactly one focus
  /// node to directional traversal.
  final DpadDirectionCallback? onDirection;

  const DpadSourceButton({
    super.key,
    required this.icon,
    required this.label,
    this.tooltip,
    required this.onPressed,
    this.isPrimary = false,
    this.focusNode,
    this.onDirection,
  });

  @override
  State<DpadSourceButton> createState() => _DpadSourceButtonState();
}

class _DpadSourceButtonState extends State<DpadSourceButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final glass = GlassPalette.of(context);
    final enabled = widget.onPressed != null;

    if (!enabled) {
      return SourceActionSemantics(
        enabled: false,
        child: ExcludeFocus(
          child: Tooltip(
            message: widget.tooltip ?? '',
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: glass.ink.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: glass.ink.withValues(alpha: 0.06),
                  width: 0.8,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    widget.icon,
                    size: 14,
                    color: glass.ink.withValues(alpha: 0.25),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: glass.ink.withValues(alpha: 0.25),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return DpadFocusable(
      focusNode: widget.focusNode,
      onSelect: widget.onPressed,
      onDirection: widget.onDirection,
      child: const SizedBox.shrink(),
      builder: (context, state, _) {
        final isFocused = state.focused;
        final highlight = isFocused || _isHovered;

        final Color bgColor;
        final Color borderColor;
        final Color contentColor;

        if (widget.isPrimary) {
          if (highlight) {
            bgColor = glass.raisedFill;
            borderColor = glass.raisedBorder;
            contentColor = sourceSheetAccent;
          } else {
            bgColor = sourceSheetAccent;
            borderColor = sourceSheetAccent;
            contentColor = glass.onAccent;
          }
        } else {
          if (highlight) {
            bgColor = sourceSheetAccent.withValues(alpha: 0.20);
            borderColor = sourceSheetAccent;
            contentColor = glass.ink;
          } else {
            bgColor = glass.ink.withValues(alpha: 0.06);
            borderColor = glass.ink.withValues(alpha: 0.12);
            contentColor = glass.ink.withValues(alpha: 0.85);
          }
        }

        return SourceActionSemantics(
          enabled: true,
          child: Tooltip(
            message: widget.tooltip ?? widget.label,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                // DpadFocusable already publishes this chip's focus node; a
                // focusable InkWell would add a second one over the same rect
                // and directional traversal would settle on that instead.
                canRequestFocus: false,
                onTap: widget.onPressed,
                overlayColor: WidgetStateProperty.all(Colors.transparent),
                hoverColor: Colors.transparent,
                splashColor: Colors.transparent,
                highlightColor: Colors.transparent,
                onHover: (hovered) {
                  if (_isHovered != hovered) {
                    setState(() => _isHovered = hovered);
                  }
                },
                borderRadius: BorderRadius.circular(6),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: bgColor,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: borderColor, width: 1.0),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(widget.icon, size: 14, color: contentColor),
                      const SizedBox(width: 4),
                      Text(
                        widget.label,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: contentColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
/// Working / dead / testing indicator driven by [LinkProbeService].
class ProbeBadge extends StatelessWidget {
  final LinkProbeResult? probe;
  final bool probing;
  final bool isPeerToPeer;

  const ProbeBadge({
    super.key,
    required this.probe,
    required this.probing,
    this.isPeerToPeer = false,
  });

  static String _shortReason(String? reason) {
    if (reason == null || reason.isEmpty) return 'Dead link';
    final lower = reason.toLowerCase();
    if (lower.contains('failed host lookup') ||
        lower.contains('socketexception') ||
        lower.contains('connection refused') ||
        lower.contains('connection terminated')) {
      return 'Unreachable';
    }
    if (lower.contains('timeout') || lower.contains('timed out')) {
      return 'Timed out';
    }
    if (lower.contains('403') || lower.contains('forbidden')) {
      return 'Blocked (403)';
    }
    if (lower.contains('404') || lower.contains('not found')) {
      return 'Not found (404)';
    }
    if (lower.contains('500') ||
        lower.contains('502') ||
        lower.contains('503')) {
      return 'Server error';
    }
    if (reason.length > 18) {
      return 'Dead link';
    }
    return reason;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    if (isPeerToPeer) {
      return Text(
        'P2P',
        style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
      );
    }
    if (probing) {
      return SizedBox(
        width: 10,
        height: 10,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: cs.primary),
      );
    }
    final result = probe;
    if (result == null) return const SizedBox.shrink();
    if (result.reachable) {
      return const SizedBox.shrink();
    }

    final reason = _shortReason(result.failureReason);
    final isNotFound = reason.toLowerCase().contains('not found');
    final isUnreachable = reason.toLowerCase().contains('unreachable');
    final Color badgeColor = isNotFound
        ? const Color(0xFFEF4444) // var(--text-danger)
        : (isUnreachable ? const Color(0xFFF59E0B) : cs.error); // var(--text-warning)
    final IconData badgeIcon = isNotFound
        ? Icons.cancel_rounded // circle-x
        : (isUnreachable ? Icons.warning_amber_rounded : Icons.error_outline_rounded); // alert-triangle

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 130),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(badgeIcon, size: 12, color: badgeColor),
          const SizedBox(width: 2),
          Flexible(
            child: Text(
              reason,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: badgeColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Wraps the Play / Download row of a source card.
///
/// **Focus.** The cards are the UP/DOWN stops; the buttons are reached with
/// LEFT/RIGHT once a card holds focus. Because the row sits at the bottom edge
/// of the card, from a neighbouring card those buttons pass Flutter's
/// directional filter (`centre.dy <= target.top` going up) and then win on
/// distance against the card they belong to — UP from card 3 lands on card 2's
/// Play button instead of card 2. Making the row untraversable unless
/// [cardFocusNode] holds focus keeps other cards' buttons out of the
/// candidate set entirely, while the focused card's own buttons stay in it so
/// LEFT/RIGHT (and Tab on desktop) resolve natively between them.
///
/// The buttons stay *focusable* the whole time — only traversal is gated — so
/// a card's key handler can still call `requestFocus()` on them directly.
///
/// **Hit target.** The chips paint at ~26dp so the cards keep their height;
/// [_TapTargetBand] widens the band that accepts pointers to
/// [kMinInteractiveDimension] without changing what is laid out or painted.
class SourceCardActions extends StatefulWidget {
  /// The focus node of the card this row belongs to. It must be an ancestor of
  /// the row, which is how a focused button keeps the card "in focus".
  final FocusNode cardFocusNode;
  final Widget child;

  const SourceCardActions({
    super.key,
    required this.cardFocusNode,
    required this.child,
  });

  @override
  State<SourceCardActions> createState() => _SourceCardActionsState();
}

class _SourceCardActionsState extends State<SourceCardActions> {
  late bool _cardHasFocus = widget.cardFocusNode.hasFocus;

  @override
  void initState() {
    super.initState();
    widget.cardFocusNode.addListener(_handleCardFocusChange);
  }

  @override
  void didUpdateWidget(SourceCardActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.cardFocusNode, widget.cardFocusNode)) {
      oldWidget.cardFocusNode.removeListener(_handleCardFocusChange);
      widget.cardFocusNode.addListener(_handleCardFocusChange);
      _cardHasFocus = widget.cardFocusNode.hasFocus;
    }
  }

  @override
  void dispose() {
    widget.cardFocusNode.removeListener(_handleCardFocusChange);
    super.dispose();
  }

  void _handleCardFocusChange() {
    final hasFocus = widget.cardFocusNode.hasFocus;
    if (hasFocus != _cardHasFocus && mounted) {
      setState(() => _cardHasFocus = hasFocus);
    }
  }

  @override
  Widget build(BuildContext context) {
    // The band has to be the outermost box: [Focus] wraps its child in a
    // [Semantics] proxy, and a proxy's bounds check would reject the pointer
    // before it ever reached the band.
    return _TapTargetBand(
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        descendantsAreTraversable: _cardHasFocus,
        child: widget.child,
      ),
    );
  }
}

/// Gives a hand-built action chip the button role assistive tech expects.
///
/// The chips are bare [InkWell]s — and a plain [Container] when disabled — so
/// nothing in the subtree reports a role or a disabled state on its own. The
/// chip's own [Text] supplies the label unless [label] overrides it.
class SourceActionSemantics extends StatelessWidget {
  final bool enabled;
  final String? label;
  final Widget child;

  const SourceActionSemantics({
    super.key,
    required this.enabled,
    this.label,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: child,
    );
  }
}

/// Accepts pointers within [kMinInteractiveDimension] of its child's centre
/// line, folding a near miss onto the row so it reaches whichever chip is
/// under the finger.
///
/// Layout and painting are untouched: a taller box here would push every card
/// taller, and a hit area cannot extend past an ancestor's bounds, so the
/// growth has to happen at the row rather than around each chip.
///
/// That ancestor rule also makes the band ASYMMETRIC in practice. The action
/// row is the last child of the card's Column, so a pointer below it is
/// already outside the Column and is rejected before it reaches here; only the
/// upward half is live. A tap in the gap below the chips therefore falls
/// through to the card itself, which is the intended behaviour for Play and a
/// known rough edge for Download. The maths below stays symmetric because it
/// is the correct general rule, not because both halves fire here.
class _TapTargetBand extends SingleChildRenderObjectWidget {
  const _TapTargetBand({required Widget super.child});

  @override
  _RenderTapTargetBand createRenderObject(BuildContext context) =>
      _RenderTapTargetBand();
}

class _RenderTapTargetBand extends RenderProxyBox {
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (super.hitTest(result, position: position)) return true;

    final RenderBox? child = this.child;
    if (child == null) return false;

    final overhang = (kMinInteractiveDimension - size.height) / 2;
    if (overhang <= 0) return false;
    if (position.dx < 0 || position.dx > size.width) return false;
    if (position.dy < -overhang || position.dy > size.height + overhang) {
      return false;
    }

    final folded = Offset(position.dx, size.height / 2);
    return result.addWithRawTransform(
      transform: MatrixUtils.forceToPoint(folded),
      position: position,
      hitTest: (BoxHitTestResult result, Offset position) {
        assert(position == folded);
        return child.hitTest(result, position: folded);
      },
    );
  }
}

/// Best-guess container extension for a link, used when naming downloads.
String extensionForUrl(String url) {
  final clean = url.split('?').first.toLowerCase();
  for (final ext in const ['.mp4', '.mkv', '.webm', '.avi', '.mov']) {
    if (clean.endsWith(ext)) return ext;
  }
  return '.mp4';
}

