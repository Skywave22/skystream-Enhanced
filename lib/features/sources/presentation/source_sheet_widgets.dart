import 'dart:ui' as ui;

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../core/network/link_probe_service.dart';

/// The sheets' accent is [ColorScheme.primary]: it is what the rest of the
/// app is drawn with, and it follows dynamic colour. It used to be the
/// player's own `HotstarPlayerStyle.accent`, a fixed literal, which made the
/// three sheets the one part of the app that ignored the user's theme.
///
/// The player keeps that literal for its own chrome - its controls sit over
/// video, not over an app surface, so they answer to a different problem.

/// Why a sources sheet was opened. Both actions stay on every row; the mode
/// only decides the default tap action and the initial filtering.
enum SourcesMode { play, download }

/// Small coloured pill used for quality/source tags.
class SourceTag extends StatelessWidget {
  const SourceTag({
    super.key,
    required this.text,
    required this.container,
    required this.onContainer,
  });

  final String text;

  /// A Material 3 container/on-container pair. It used to be one colour the
  /// widget then faded to 18% for the fill and 50% for the border, and the
  /// call sites passed `deepPurpleAccent` and `teal` - hues that belong to no
  /// scheme and follow no theme.
  final Color container;
  final Color onContainer;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: container,
        borderRadius: BorderRadius.circular(kSourceSheetChipRadius),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: onContainer,
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
    required this.cardHoverFill,
    required this.raisedFill,
    required this.raisedBorder,
    required this.onAccent,
  });

  /// Backdrop tint painted behind the blur.
  final Color pane;

  /// Drop shadow under the whole panel.
  final Color paneShadow;

  /// Text, icons and hairlines drawn on the glass. Callers dial it down with
  /// `withValues(alpha:)` rather than reaching for another literal.
  final Color ink;

  /// Fill behind the focused row.
  final Color cardFocusFill;

  /// Fill behind a row the pointer is over. Lighter than [cardFocusFill]:
  /// hovering is a maybe, focus is a choice.
  final Color cardHoverFill;

  /// Fill and border of an action chip lifted out of the accent, i.e. the
  /// focused or hovered Play button.
  final Color raisedFill;
  final Color raisedBorder;

  /// Content on a solid accent fill.
  final Color onAccent;

  /// [ink] at [alpha]. Every overlay fill and hairline on the glass is the
  /// ink at some alpha, so this saves the call sites reaching for a literal.
  Color tint(double alpha) => ink.withValues(alpha: alpha);

  /// Hairline around the panel and, at rest, around a row.
  Color get edge => tint(0.12);

  /// Placeholder glyph where artwork is missing or still loading.
  Color get mutedIcon => tint(0.38);

  /// Fill behind artwork that is missing or still loading.
  Color get imageFill => tint(0.06);

  /// Every colour here but [pane] is a Material 3 scheme role, so the sheets
  /// pick up the app's theme - and its dynamic colour - instead of carrying a
  /// palette of their own. They used to be two tables of hand-mixed literals
  /// per brightness, which is how 0xFF16161C and 0xFF15151C ended up being the
  /// same intention in two files.
  ///
  /// [pane] stays a literal on purpose: it is a translucent tint over whatever
  /// is *behind* the sheet, not a surface the scheme knows about. A
  /// `surfaceContainerHigh` at 65% would take its opacity from a colour chosen
  /// to be read opaque, and the blur behind it would stop reading as glass.
  static GlassPalette of(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return GlassPalette._(
      pane: isDark ? const Color(0xA6060608) : const Color(0xA6F4F4F7),
      paneShadow: cs.shadow.withValues(alpha: isDark ? 0.50 : 0.18),
      ink: cs.onSurface,
      cardFocusFill: cs.secondaryContainer,
      cardHoverFill: cs.surfaceContainerHighest.withValues(alpha: 0.70),
      raisedFill: cs.primaryContainer,
      raisedBorder: cs.primary,
      onAccent: cs.onPrimary,
    );
  }
}

/// Corner radius of the small pills - chips, tags, quality badges. Material 3
/// draws its small components at 8.
const double kSourceSheetChipRadius = 8;

/// Horizontal inset every band of a source sheet shares - header, status
/// strip, filter rail, list.
///
/// Both sheets had grown a number per band: one header at 18 left and 12
/// right, a status strip at 18, a filter rail at 16 and a list at 14 with its
/// section labels nudged 2 back to fake a 16; the other a header at 18 and a
/// list at 14. Nothing lined up with anything above or below it.
const double kSourceSheetGutter = 16;

/// Glyph size both sheets give the icon buttons in their headers.
const double kSourceSheetHeaderIcon = 20;

/// Side of a header's trailing buttons - the touch target, and with a filled
/// background also the circle that gets drawn.
const double kSourceSheetHeaderButton = kMinInteractiveDimension;

/// Gap between two of those buttons. They each carry a filled circle, so
/// without it the two circles meet and read as one lozenge.
const double kSourceSheetHeaderGap = 8;

/// The floating glass panel both source sheets are drawn in.
///
/// The two sheets answer the same question a step apart - which episode, then
/// which link - and were built as one design. They had drifted anyway, because
/// the panel was ninety lines of chrome copied into each: by the time anyone
/// looked, the light pane was 0xA6F4F4F7 in one and 0xA6F4F4F8 in the other,
/// the ink 0xFF16161C against 0xFF15151C, the focus fill 0xFFE6E6EE against
/// 0xFFE2E2EA, and one of them still dropped a 50%-black shadow under a pale
/// panel. None of that was decided; it was just never merged. One scaffold
/// means the next change reaches both.
class GlassSheetScaffold extends StatelessWidget {
  const GlassSheetScaffold({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.actions = const <Widget>[],
    this.onClose,
  });

  /// Header title. Already localised by the caller.
  final String title;

  /// Second line under the title - what the sheet is about.
  final String? subtitle;

  /// Buttons before the close button. The close button itself belongs to the
  /// scaffold, so the two sheets cannot end up closing differently.
  final List<Widget> actions;

  /// Defaults to popping the enclosing route.
  final VoidCallback? onClose;

  /// The sheet's content, below the header. Give it an [Expanded] of its own
  /// for whatever scrolls.
  final Widget child;

  /// Widest and tallest the panel is drawn.
  static const double maxWidth = 580;
  static const double maxHeight = 680;

  /// Corner radius of the panel and its hairline. Material 3 draws a dialog
  /// at 28.
  static const double radius = 28;

  /// Blur behind the pane.
  static const double blurSigma = 22;

  /// Height of one line of the header's title, measured off `titleMedium` at
  /// the weight below. The close button is centred against this rather than
  /// against the two-line block beside it - at the block's centre it floats
  /// between title and subtitle, and the eye pairs a dialog's close
  /// affordance with its title.
  static const double titleLineHeight = 24;

  /// Half the amount a header button overhangs a [titleLineHeight] line.
  /// Pushing the text down by this gives the two a shared centre, which is
  /// what puts the close button on the title's line rather than floating it
  /// between the title and the subtitle.
  static const double _closeOverhang =
      (kSourceSheetHeaderButton - titleLineHeight) / 2;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = GlassPalette.of(context);

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.zero,
      elevation: 0,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Center(
              child: GestureDetector(
                // Swallows taps on the panel so they do not reach the barrier
                // handler above and close the sheet.
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: maxWidth,
                    maxHeight: maxHeight,
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(radius),
                      boxShadow: [
                        BoxShadow(
                          // Themed: a 50%-black drop under a pale panel in
                          // light mode was a bruise.
                          color: palette.paneShadow,
                          blurRadius: 50,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(radius),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // Translucent obsidian base behind a backdrop blur.
                          Positioned.fill(
                            child: BackdropFilter(
                              filter: ui.ImageFilter.blur(
                                sigmaX: blurSigma,
                                sigmaY: blurSigma,
                              ),
                              child: DecoratedBox(
                                decoration: BoxDecoration(color: palette.pane),
                              ),
                            ),
                          ),
                          // Hairline edge on the glass. It used to be wrapped
                          // in a full-bleed ShaderMask that faded the line out
                          // over the top and bottom 15% of the panel: a
                          // BlendMode.dstIn mask costs an offscreen surface the
                          // size of the whole sheet, and what it bought was a
                          // gradient between "0.5 dp line at 12% ink" and "no
                          // line at all" - a transition between two states that
                          // are already at the edge of visible. The line itself
                          // is kept, and closes around every corner.
                          Positioned.fill(
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(radius),
                                  border: Border.all(
                                    color: palette.edge,
                                    width: 0.5,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Positioned.fill(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _header(context, theme, palette),
                                Expanded(child: child),
                              ],
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
        ),
      ),
    );
  }

  Widget _header(BuildContext context, ThemeData theme, GlassPalette palette) {
    final cs = theme.colorScheme;
    return Padding(
      // The full gutter on both sides. The trailing buttons are drawn as
      // filled circles, so the circle IS their visible box and lines up like
      // any other. This used to pull the end inset back by the slack a BARE
      // glyph leaves inside its touch target - right while they were bare
      // glyphs, wrong the moment they got a background: at 2 dp the circle ran
      // into the panel's 28 dp corner and was clipped.
      padding: const EdgeInsets.fromLTRB(
        kSourceSheetGutter,
        kSourceSheetGutter,
        kSourceSheetGutter,
        4,
      ),
      // A Stack, not a Row: the trailing buttons line up with the TITLE, and a
      // Row centres them on the whole two-line block instead. Taking them out
      // of the flow also stops their 48 dp targets pushing the subtitle down by
      // the difference between that and a 24 dp line.
      child: SizedBox(
        width: double.infinity,
        child: Stack(
          children: [
            Padding(
              // Down by half the buttons' overhang, so the title's centre line
              // lands on theirs; across by their width so a long subtitle
              // cannot run underneath them.
              padding: EdgeInsetsDirectional.fromSTEB(
                0,
                _closeOverhang,
                kSourceSheetHeaderButton * (actions.length + 1) +
                    kSourceSheetHeaderGap * actions.length,
                0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: palette.ink,
                      letterSpacing: -0.2,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            PositionedDirectional(
              top: 0,
              end: 0,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final action in actions) ...[
                    action,
                    const SizedBox(width: kSourceSheetHeaderGap),
                  ],
                  // Circled like the action buttons beside it: a bare
                  // glyph next to a filled one reads as two different
                  // kinds of control rather than two of the same kind.
                  DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: cs.error.withValues(alpha: 0.12),
                    ),
                    child: IconButton(
                      tooltip: MaterialLocalizations.of(context)
                          .closeButtonTooltip,
                      // Compact density would make this a 40 dp target, and
                      // desktop picks compact by default; pinning standard keeps
                      // 48 dp on every platform.
                      visualDensity: VisualDensity.standard,
                      icon: Icon(
                        Icons.close_rounded,
                        size: kSourceSheetHeaderIcon,
                        color: cs.error,
                      ),
                      hoverColor: cs.error.withValues(alpha: 0.12),
                      highlightColor: cs.error.withValues(alpha: 0.16),
                      onPressed:
                          onClose ?? () => Navigator.of(context).maybePop(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The shell every row in a source sheet is drawn in.
///
/// The fill, the hairline, the focus ring and the corner - everything except
/// what the row is *about*. The two sheets had two of these at radius 10 and
/// 12, padding `h12/v9` and `all(8)`, border widths 1.2/2 and a flat 1.5, one
/// with a hairline at rest and one transparent, one with a drop shadow under a
/// blurred glass panel.
///
/// Focus comes from the caller's [DpadFocusable] rather than a node of this
/// widget's own: a second node over the same rect makes every row two stops on
/// a D-pad.
class GlassRow extends StatefulWidget {
  const GlassRow({
    super.key,
    required this.focused,
    required this.onTap,
    required this.child,
    this.accented = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
  });

  /// Whether the caller's focus node holds focus.
  final bool focused;

  final VoidCallback? onTap;
  final Widget child;

  /// Draws the accent border at rest - the sheet's "top pick".
  final bool accented;

  final EdgeInsetsGeometry padding;

  /// Corner radius shared by the fill, the ink splash and the border.
  static const double radius = 12;

  @override
  State<GlassRow> createState() => _GlassRowState();
}

class _GlassRowState extends State<GlassRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final palette = GlassPalette.of(context);
    final radius = BorderRadius.circular(GlassRow.radius);

    final Color fill;
    if (widget.focused) {
      fill = palette.cardFocusFill;
    } else if (_hovered) {
      fill = palette.cardHoverFill;
    } else {
      fill = Colors.transparent;
    }

    // Focus is the one state a viewer ten feet away has to read at a glance,
    // so it gets its own colour and weight rather than the accent a top pick
    // already wears permanently.
    final Color border;
    if (widget.focused) {
      border = palette.ink;
    } else if (_hovered || widget.accented) {
      border = cs.primary;
    } else {
      border = palette.tint(0.08);
    }

    return Material(
      color: fill,
      borderRadius: radius,
      child: InkWell(
        // The caller's DpadFocusable already publishes this row's node; a
        // focusable InkWell would add a second one over the same rect and
        // traversal would settle on that instead.
        canRequestFocus: false,
        onTap: widget.onTap,
        borderRadius: radius,
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        hoverColor: Colors.transparent,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        onHover: (hovered) {
          if (_hovered != hovered) setState(() => _hovered = hovered);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: widget.padding,
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: border, width: widget.focused ? 2 : 1.2),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// A filter pill on a source sheet.
///
/// Shared because the two sheets had drifted apart: three copies of this in
/// one and a fourth in the other, each spelling out its own selected and
/// unselected colours, and every one of them leaving the checkmark to the
/// theme. That is what made the tick disappear. A selected chip fills with
/// `colorScheme.primary` and forces its label to `onPrimary`, but the
/// checkmark fell through to the theme - and the dark theme declares no
/// `chipTheme` at all, while the light one sets `checkmarkColor: primary`,
/// which is exactly the colour of the fill it is drawn on. Tying the tick to
/// the label is the fix; one widget instead of four is what stops it coming
/// back.
class SourceFilterChip extends StatelessWidget {
  const SourceFilterChip({
    super.key,
    required this.text,
    required this.selected,
    required this.onSelected,
    required this.outline,
  });

  /// The chip's text. Named [text] and not `label` because [FilterChip.label]
  /// takes a widget and this takes a string.
  final String text;

  final bool selected;
  final ValueChanged<bool> onSelected;

  /// Border drawn while unselected. A selected chip has its fill instead.
  final Color outline;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // One colour for the tick and the label, resolved once. This is the whole
    // bug fix; everything else here is the four copies becoming one.
    final Color content = selected ? cs.onPrimary : cs.onSurfaceVariant;

    return FilterChip(
      visualDensity: VisualDensity.compact,
      label: Text(text, style: const TextStyle(fontSize: 11)),
      selected: selected,
      selectedColor: cs.primary,
      checkmarkColor: content,
      labelStyle: TextStyle(
        fontSize: 11,
        color: content,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      ),
      side: BorderSide(
        color: selected ? Colors.transparent : outline,
        width: 1,
      ),
      backgroundColor: Colors.transparent,
      onSelected: onSelected,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kSourceSheetChipRadius),
      ),
    );
  }
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

    // Tonal containers rather than a hue picked per tier. The scheme offers
    // three accent families, which is as many resolution tiers as are worth
    // telling apart; everything else is neutral.
    final (Color container, Color onContainer) = switch (res) {
      _
          when res.contains('4K') ||
              res.contains('2160') ||
              res.contains('UHD') =>
        (cs.tertiaryContainer, cs.onTertiaryContainer),
      _ when res.contains('1080') => (
        cs.primaryContainer,
        cs.onPrimaryContainer,
      ),
      _ when res.contains('720') => (
        cs.secondaryContainer,
        cs.onSecondaryContainer,
      ),
      _ => (cs.surfaceContainerHighest, cs.onSurfaceVariant),
    };

    return Container(
      constraints: const BoxConstraints(maxWidth: 80),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
      decoration: BoxDecoration(
        color: container,
        borderRadius: BorderRadius.circular(kSourceSheetChipRadius),
      ),
      child: Text(
        resolution,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: onContainer,
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

        // Material 3 button roles rather than one accent at four alphas: a
        // filled button at rest, its tonal container when it lifts, and a
        // tonal/outlined pair for the secondary action.
        final cs = Theme.of(context).colorScheme;
        if (widget.isPrimary) {
          if (highlight) {
            bgColor = glass.raisedFill;
            borderColor = glass.raisedBorder;
            contentColor = cs.onPrimaryContainer;
          } else {
            bgColor = cs.primary;
            borderColor = cs.primary;
            contentColor = glass.onAccent;
          }
        } else {
          if (highlight) {
            bgColor = cs.secondaryContainer;
            borderColor = cs.primary;
            contentColor = cs.onSecondaryContainer;
          } else {
            bgColor = cs.surfaceContainerHighest;
            borderColor = cs.outlineVariant;
            contentColor = cs.onSurfaceVariant;
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
    // Error for a link that is definitively gone, tertiary for one that only
    // failed to answer - the scheme's two ways of saying "look at this".
    final Color badgeColor = isUnreachable ? cs.tertiary : cs.error;
    final IconData badgeIcon = isNotFound
        ? Icons
              .cancel_rounded // circle-x
        : (isUnreachable
              ? Icons.warning_amber_rounded
              : Icons.error_outline_rounded); // alert-triangle

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
