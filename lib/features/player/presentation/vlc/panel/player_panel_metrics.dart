/// The panel's type scale, insets and text alphas — one ramp for a thumb, one
/// for a sofa.
///
/// Every number in the panel was drawn for a phone: a 10 sp badge is twenty
/// physical pixels on a 1080p panel at dp 2.0, and `secondaryText` at 65 %
/// white disappears into a consumer set's picture modes. So the sizes live here
/// rather than as literals in the widgets, and the widgets ask the tree which
/// ramp they are on.
///
/// An inherited widget rather than a theme or a constructor argument: the panel
/// is a [PopupRoute], so it inherits nothing from the screen's tree and cannot
/// read what the player knows about the form factor, and the parts that need
/// the ramp are built inside five tab widgets this file does not own.
///
/// [PlayerPanelMetrics.touch] is every literal the widgets carried before this
/// file existed, so phone, tablet and desktop are unchanged.
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
  /// 13 on the TV ramp, deliberately below the 14 sp floor the rest of it
  /// clears: three badges plus a Now-playing chip have to fit one line of a
  /// [drawerMinWidth] drawer, and widening the drawer past 460 dp costs picture
  /// on the one screen where the panel covers what it is describing.
  final double badgeSize;

  final double subheaderSize;
  final double emptySize;

  /// The Sources tab's fallback banner — the sentence that says why sources
  /// below the viewer's quality preference are in the list. Its own rung rather
  /// than [rowDetailSize] because the phone's 11 sp predates this file.
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
  /// is a mis-tap. The vertical padding already makes a tab 41 dp tall; this is
  /// the same guarantee across.
  ///
  /// The one touch field that is not a pre-existing literal: the [Wrap] that
  /// stopped `Subtitles` being ellipsised on a television let every tab shrink
  /// to its word, and this puts the floor back.
  ///
  /// 48 on both ramps, where every other rung goes up for the sofa. A remote
  /// does not aim, the narrowest TV tab is already 51 dp, and a 64 dp rung buys
  /// nothing in English or Hindi while pushing the Kannada strip from one run
  /// to two.
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
  /// label. A television's picture modes crush 65 % white, so the TV ramp
  /// raises it to 85 %.
  final Color secondaryText;

  /// Third-rank text: a row's detail line, a subheader, an empty state. 45 %
  /// white on the phone, 65 % on a television.
  final Color mutedText;

  /// Hairline between the header and the body, and around a badge with no
  /// colour of its own. At 12 % white a badge on a television has no outline
  /// at all, which is most of what makes a badge a badge.
  final Color divider;

  /// Every number as it was hard-coded before this file existed, with the one
  /// exception of [tabMinWidth], which restores a floor the [Wrap] removed.
  /// Changing any of the others is a phone, tablet and desktop redesign.
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
