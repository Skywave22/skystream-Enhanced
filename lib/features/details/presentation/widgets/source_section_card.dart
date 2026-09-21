import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';

import '../../../../core/utils/layout_constants.dart';

/// The chrome shared by the two source-discovery blocks on a details screen.
///
/// A details screen offers streams from two independent plugin systems -
/// SkyStream providers and Nuvio scrapers - and neither is subordinate to the
/// other. They used to be drawn as different *kinds* of thing: the SkyStream
/// results sat in a quiet tonal card while Nuvio was a saturated primary
/// button, which read as one feature and one call to action rather than two
/// peers. Giving both the same container is what makes the ranking between
/// them a matter of order alone.
///
/// The two are peers in billing, not in behaviour. SkyStream results are
/// searched as the page builds and shown inline; Nuvio resolves behind a tap,
/// because running every scraper on page load is expensive.
class SourceSectionCard extends StatelessWidget {
  const SourceSectionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.child,
    this.badge,
    this.trailing,
    this.compact = false,
    this.showHeader = true,
    this.minHeight,
  });

  /// Leading glyph in the header, tinted with the accent.
  final IconData icon;

  /// Header text. Already localised by the caller.
  final String title;

  /// The block's content, laid out under the header.
  final Widget child;

  /// Optional pill after the title - a BETA tag, a count.
  final Widget? badge;

  /// Optional controls at the far end of the header row.
  final Widget? trailing;

  /// Drops the container and enlarges the header, for a caller that is already
  /// inside a padded panel of its own. The desktop hero uses this.
  final bool compact;

  /// Whether the header row is drawn at all.
  final bool showHeader;

  /// Floor for the card's height, so a block whose content arrives late does
  /// not pop the page as it loads.
  final double? minHeight;

  /// Horizontal inset of the header, and of any content that does not
  /// deliberately bleed to the card's edge.
  static const double gutter = LayoutConstants.spacingMd;

  /// Radius of the container, matched to the other panels on a details screen.
  static const double radius = LayoutConstants.radiusXl;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showHeader) ...[
          _header(context, cs),
          SizedBox(height: compact ? 12 : LayoutConstants.spacingSm),
        ],
        // ClipRect, not clipBehavior on the container: the content is a
        // horizontal rail that scrolls under the card's edge, and it has to be
        // clipped to the card's box whether or not that box is painted.
        ClipRect(child: child),
      ],
    );

    if (compact) return column;

    return Container(
      width: double.infinity,
      constraints: minHeight == null
          ? null
          : BoxConstraints(minHeight: minHeight!),
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: cs.outline.withValues(alpha: 0.1)),
      ),
      padding: const EdgeInsets.symmetric(vertical: LayoutConstants.spacingMd),
      child: column,
    );
  }

  Widget _header(BuildContext context, ColorScheme cs) {
    return Padding(
      padding: compact
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: gutter),
      child: Row(
        children: [
          // The whole label group is one Expanded child, so the trailing
          // controls are pinned to the end. A Spacer next to the Flexible
          // title does NOT do that: both carry flex 1, so they split the free
          // space between them and the title's unused half is left over,
          // leaving the arrows stranded short of the edge.
          Expanded(
            child: Row(
              children: [
                Icon(icon, size: compact ? 20 : 18, color: cs.primary),
                const SizedBox(width: 8),
                // Flexible so a long title in a locale with compound nouns
                // ellipsises rather than overflowing.
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 18 : 14,
                      fontWeight: FontWeight.bold,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                if (badge != null) const SizedBox(width: 8),
                ?badge,
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Small pill for a [SourceSectionCard] header - a BETA tag, a scraper count.
class SourceSectionBadge extends StatelessWidget {
  const SourceSectionBadge({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(LayoutConstants.radiusSm),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: cs.primary,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// Widest a source card's action is drawn on a desktop, where the card's
/// column can run far wider than any button should be.
const double kSourceActionDesktopWidth = 500;

/// The tonal action inside a [SourceSectionCard].
///
/// Tonal rather than filled so it sits INSIDE its card instead of competing
/// with it, and [DpadFocusable] rather than a plain button so a remote gets
/// the same one-stop focus treatment the rest of a details screen uses.
///
/// Shared by the Nuvio and Stremio cards. They are the same control with a
/// different label; two copies is how the sheets drifted.
///
/// Tonal rather than filled so it sits *inside* its card instead of competing
/// with it, and [DpadFocusable] rather than a plain button so a remote gets
/// the same one-stop focus treatment the rest of the details screen uses.
class SourceSectionAction extends StatelessWidget {
  const SourceSectionAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    required this.maxWidth,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  /// Widest the control may be drawn, or null to fill its parent.
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const radius = LayoutConstants.radiusLg;

    final button = DpadFocusable(
      onSelect: onTap,
      child: const SizedBox.shrink(),
      builder: (context, state, _) {
        final isFocused = state.focused;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            color: cs.primary.withValues(alpha: isFocused ? 0.22 : 0.10),
            border: Border.all(
              color: isFocused
                  ? cs.primary
                  : cs.primary.withValues(alpha: 0.35),
              width: isFocused ? 2 : 1,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              // DpadFocusable already publishes this control's focus node; a
              // focusable InkWell would add a second one over the same rect
              // and traversal would settle on that instead.
              canRequestFocus: false,
              borderRadius: BorderRadius.circular(radius),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: LayoutConstants.spacingMd,
                  vertical: 14,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 20, color: cs.primary),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: cs.primary,
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
    );

    final cap = maxWidth;
    if (cap == null) return button;
    // Align hands the ConstrainedBox loose constraints, so the Row inside
    // settles on the cap instead of the full column width.
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: cap),
        child: button,
      ),
    );
  }
}
