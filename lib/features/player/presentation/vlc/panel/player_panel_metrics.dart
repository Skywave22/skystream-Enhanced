/// The panel's type scale, insets and text alphas — one ramp for a thumb, one
/// for a sofa.
///
/// The panel is the surface a television viewer reads longest and the only way
/// to change source, track or episode without leaving playback, and every
/// number in it was drawn for a phone: a 10 sp badge is twenty physical pixels
/// on a 1080p panel at dp 2.0, and `secondaryText` at 65 % white disappears
/// into a consumer set's picture modes. So the sizes live here rather than as
/// literals in the widgets, and the widgets ask the tree which ramp they are
/// on.
///
/// WHY AN INHERITED WIDGET AND NOT A THEME OR A CONSTRUCTOR ARGUMENT. The panel
/// is a [PopupRoute] (`showPlayerPanel` pushes `_PlayerPanelRoute`), so it
/// inherits nothing from the screen's tree and cannot read whatever the player
/// knows about the form factor. And the parts that need the ramp — a row, a
/// badge, a subheader — are built inside five tab widgets that this item does
/// not own, so threading a parameter through would touch every one of them.
/// One scope installed once in `PlayerPanel.build` reaches all of them without
/// a single new argument.
///
/// WHY IT IS SCOPED TO THE PANEL. A repo-wide TV scale would have to solve the
/// bottom bar's missing overflow escape in the same change. This is the panel's
/// ramp and nothing else's.
///
/// THE TOUCH RAMP IS TODAY'S LITERALS, EXACTLY. [PlayerPanelMetrics.touch] is
/// not a redesign of the phone: every field is the number that was hard-coded
/// in the widget before this file existed, which is what makes phone, tablet
/// and desktop a provable no-op rather than a hopeful one. There is a test that
/// pins each of them.
library;

import 'package:flutter/widgets.dart';

import '../../widgets/hotstar_player_style.dart';

/// Sizes, insets and alphas for one form factor's worth of panel.
@immutable
class PlayerPanelMetrics {
  const PlayerPanelMetrics({
    required this.drawerMinWidth,
    required this.drawerMaxWidth,
    required this.drawerEdgeInset,
    required this.drawerVerticalInset,
    required this.rowLabelSize,
    required this.rowDetailSize,
    required this.rowVerticalPadding,
    required this.leadingSlotWidth,
    required this.iconSize,
    required this.badgeSize,
    required this.subheaderSize,
    required this.emptySize,
    required this.bannerTextSize,
    required this.bannerIconSize,
    required this.tabLabelSize,
    required this.tabVerticalPadding,
    required this.tabHorizontalPadding,
    required this.tabMinWidth,
    required this.closeButtonPadding,
    required this.stepperValueWidth,
    required this.stepperValueSize,
    required this.stepIconPadding,
    required this.secondaryText,
    required this.mutedText,
    required this.divider,
  });

  // --- Drawer shell ---

  /// Floor on the drawer's width. A drawer narrower than this cannot hold a
  /// release name and its row of badges without wrapping every one of them.
  final double drawerMinWidth;

  /// Cap, so the drawer never becomes a second screen on a 4K desktop window.
  final double drawerMaxWidth;

  /// Kept clear between the drawer and the right edge of the screen.
  ///
  /// Zero everywhere but a television, where it is
  /// [HotstarPlayerStyle.tvEdgeInset]: ~5 % of the edges of a consumer panel is
  /// clipped, and without this the close button and every row's right-hand
  /// badges sit in the band that gets cut off.
  final double drawerEdgeInset;

  /// The same protection top and bottom. Smaller than [drawerEdgeInset]:
  /// overscan is worse horizontally, and the drawer's own first and last rows
  /// are already inside its padding.
  final double drawerVerticalInset;

  // --- Rows ---

  final double rowLabelSize;
  final double rowDetailSize;

  /// Vertical padding inside a row. Sized so a row clears 48 dp — one focus
  /// target — once its border and its label are added.
  final double rowVerticalPadding;

  /// The fixed slot the tick or a row's icon sits in, so selected and
  /// unselected rows start their text in the same place.
  final double leadingSlotWidth;

  /// Every glyph in the panel that is not text: the tick, a row's icon, the
  /// stepper's -/+ and the close button.
  final double iconSize;

  // --- Chips and section furniture ---

  /// Quality, size, seeders, probe state.
  ///
  /// On the TV ramp this is 13, and 13 is deliberately *below* the 14 sp floor
  /// the rest of the ramp clears. Three badges plus a Now-playing chip have to
  /// fit one line of a [drawerMinWidth] drawer, and the alternative — widening
  /// the drawer past 460 dp — costs picture on the one screen where the panel
  /// is covering the thing it is describing. Documented as the exception
  /// rather than smuggled in.
  final double badgeSize;

  final double subheaderSize;
  final double emptySize;

  /// The Sources tab's fallback banner - the sentence that says why sources
  /// below the viewer's quality preference are in the list. Its own rung
  /// rather than [rowDetailSize] because the phone's 11 sp is a number that
  /// predates this file and moving it would make the touch ramp a redesign.
  final double bannerTextSize;

  /// The banner's leading glyph. Smaller than [iconSize]: it sits beside one
  /// run of prose, not in a row's leading slot.
  final double bannerIconSize;

  // --- Tab strip ---

  final double tabLabelSize;
  final double tabVerticalPadding;
  final double tabHorizontalPadding;

  /// Floor on a tab's width, because the strip is a [Wrap] of
  /// intrinsically-sized tabs: `Files` in English is 37 dp of Roboto at 13 sp
  /// plus 8 dp of padding, and a 37 dp target between two neighbours 4 dp away
  /// is a mis-tap. The vertical padding already makes a tab 41 dp tall; this
  /// is the same guarantee across.
  ///
  /// THE ONE TOUCH FIELD THAT IS NOT A PRE-EXISTING LITERAL. The strip used to
  /// be five [Expanded]s, which gave every tab an equal ~68 dp share of the
  /// header whatever its word was; the [Wrap] that stopped `Subtitles` being
  /// ellipsised on a television let every tab shrink to its word instead. This
  /// puts the floor back rather than leaving the phone paying for a TV fix.
  ///
  /// WHY IT IS 48 ON BOTH RAMPS, where every other rung goes up for the sofa.
  /// 48 dp is a thumb, and a remote does not aim: on a television the width of
  /// a tab decides how much focus ring the viewer sees, not whether they can
  /// hit it, and the narrowest TV tab today is already 51 dp. Measured, a
  /// 64 dp TV rung buys nothing in English or Hindi and pushes the Kannada
  /// strip from one run to two - 57 dp to 116 dp of a 540 dp screen, taken out
  /// of the list below it. So the floor is the touch floor, on both.
  final double tabMinWidth;

  final double closeButtonPadding;

  // --- Stepper ---

  /// The tabular-figure column the delay read-out sits in. Scaled with
  /// [stepperValueSize] or the value wraps onto a second line.
  final double stepperValueWidth;
  final double stepperValueSize;
  final double stepIconPadding;

  // --- Text alphas ---

  /// Second-rank text: a tab that is not selected, a row's icon, a badge's
  /// label. 65 % white is a phone number; a television's picture modes crush
  /// it, so the TV ramp raises it to 85 %.
  final Color secondaryText;

  /// Third-rank text: a row's detail line, a subheader, an empty state. 45 %
  /// white on the phone, 65 % on a television.
  final Color mutedText;

  /// Hairline between the header and the body, and around a badge with no
  /// colour of its own. At 12 % white a badge on a television has no outline
  /// at all, which is most of what makes a badge a badge.
  final Color divider;

  /// Every number as it was hard-coded before this file existed - with the one
  /// documented exception of [tabMinWidth], which restores a floor the ramp's
  /// own [Wrap] removed. Changing any of the others is a phone/tablet/desktop
  /// redesign, not a TV fix.
  static const PlayerPanelMetrics touch = PlayerPanelMetrics(
    drawerMinWidth: 360,
    drawerMaxWidth: 480,
    drawerEdgeInset: 0,
    drawerVerticalInset: 0,
    rowLabelSize: 14,
    rowDetailSize: 12,
    rowVerticalPadding: 10,
    leadingSlotWidth: 30,
    iconSize: 20,
    badgeSize: 10,
    subheaderSize: 11,
    emptySize: 13,
    bannerTextSize: 11,
    bannerIconSize: 16,
    tabLabelSize: 13,
    tabVerticalPadding: 10,
    tabHorizontalPadding: 4,
    tabMinWidth: 48,
    closeButtonPadding: 8,
    stepperValueWidth: 62,
    stepperValueSize: 13,
    stepIconPadding: 8,
    secondaryText: HotstarPlayerStyle.secondaryText,
    mutedText: HotstarPlayerStyle.mutedText,
    divider: HotstarPlayerStyle.divider,
  );

  /// Ten-foot. Roughly a 1.2x type scale over [touch], a 48 dp overscan inset,
  /// and paddings raised so a row and a tab are each one whole focus target.
  static const PlayerPanelMetrics tv = PlayerPanelMetrics(
    drawerMinWidth: 460,
    drawerMaxWidth: 480,
    drawerEdgeInset: HotstarPlayerStyle.tvEdgeInset,
    drawerVerticalInset: 24,
    rowLabelSize: 17,
    rowDetailSize: 14,
    rowVerticalPadding: 14,
    leadingSlotWidth: 36,
    iconSize: 24,
    badgeSize: 13,
    subheaderSize: 14,
    emptySize: 16,
    bannerTextSize: 14,
    bannerIconSize: 20,
    tabLabelSize: 16,
    tabVerticalPadding: 16,
    tabHorizontalPadding: 8,
    tabMinWidth: 48,
    closeButtonPadding: 12,
    stepperValueWidth: 76,
    stepperValueSize: 16,
    stepIconPadding: 10,
    secondaryText: Color(0xD9FFFFFF),
    mutedText: Color(0xA6FFFFFF),
    divider: Color(0x3DFFFFFF),
  );

  /// The ramp for a form factor. The panel's only decision point.
  static PlayerPanelMetrics forTv(bool isTv) => isTv ? tv : touch;

  /// The ramp in force here. [touch] when nothing installed one, so a widget
  /// from panel/ pumped on its own in a test is still the phone it always was.
  static PlayerPanelMetrics of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<PlayerPanelMetricsScope>()
          ?.metrics ??
      touch;
}

/// Publishes one [PlayerPanelMetrics] to everything below it.
///
/// Installed exactly once, by `PlayerPanel.build`, wrapping the shell.
class PlayerPanelMetricsScope extends InheritedWidget {
  const PlayerPanelMetricsScope({
    required this.metrics,
    required super.child,
    super.key,
  });

  final PlayerPanelMetrics metrics;

  @override
  bool updateShouldNotify(PlayerPanelMetricsScope oldWidget) =>
      !identical(oldWidget.metrics, metrics);
}
