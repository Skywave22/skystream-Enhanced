/// The player's one adjustable-value dialog: a read-out, a slider between two
/// step buttons, and a row of presets.
///
/// Speed and volume are the same question asked twice — one number, a range, a
/// few values worth one press — so they are one widget rather than two lists of
/// [ListTile]s that drift apart. The shape is the one the player had before the
/// engine rewrite replaced it with a bottom sheet of rows.
///
/// Applied live. There is no OK button: every change reaches the engine as it
/// is made, so the dialog is a view of a value rather than a form over it, and
/// dismissing it is never "cancel".
///
/// TEN FOOT. The slider is a read-out on a remote, not a control:
/// [CustomSlider.focusable] is false, so it is out of traversal entirely and
/// Up/Down are never trapped in it. The two step buttons are what a D-pad
/// adjusts with, and the presets are one press each.
///
/// COMPOSITING. Pushed as a [PopupRoute] with a transform-only transition, not
/// through `showDialog`. Material's dialog route fades its child, and the child
/// of a full-screen route is full-screen: that is a viewport-sized opacity
/// layer over a platform view, which is the churn vlc_player_controls.dart's
/// header forbids and player_panel.dart already avoids the same way.
library;

import 'package:flutter/material.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/custom_widgets.dart';
import '../widgets/hotstar_player_style.dart';

/// The preset row, so a test can tell a chip's label from the read-out above
/// it — `100%` is both, and only the ancestor says which.
const Key kPlayerPresetRowKey = Key('player-slider-presets');

/// Opens the dialog and completes when it closes.
///
/// [onChanged] fires on every adjustment, so the caller applies rather than
/// collects. [format] turns a value into what the read-out and the presets
/// show, so the two can never disagree about how a number is spelled.
Future<void> showPlayerSliderDialog({
  required BuildContext context,
  required String title,
  required double value,
  required double min,
  required double max,
  required double step,
  required String Function(double value) format,
  required ValueChanged<double> onChanged,
  List<double> presets = const <double>[],
  bool isTv = false,
}) {
  return Navigator.of(context).push<void>(
    _PlayerDialogRoute(
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      builder: (context) => PlayerSliderDialog(
        title: title,
        value: value,
        min: min,
        max: max,
        step: step,
        format: format,
        onChanged: onChanged,
        presets: presets,
        isTv: isTv,
      ),
    ),
  );
}

/// A modal that leaves the video playing behind it, and animates in without a
/// window-sized effect layer. See this file's header.
class _PlayerDialogRoute extends PopupRoute<void> {
  _PlayerDialogRoute({required this.builder, required this.barrierLabel});

  final WidgetBuilder builder;

  @override
  final String barrierLabel;

  @override
  Color get barrierColor => const Color(0x99000000);

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => HotstarPlayerStyle.fastMotionDuration;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => builder(context);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // A transform, and a small one: the dialog rises a little and settles.
    // Nothing here is composited separately from the layer it is already in.
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.fastOutSlowIn,
    );
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 0.04),
        end: Offset.zero,
      ).animate(curved),
      child: child,
    );
  }
}

/// The dialog itself. Split from the route so a test can pump it directly.
class PlayerSliderDialog extends StatefulWidget {
  const PlayerSliderDialog({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.format,
    required this.onChanged,
    this.presets = const <double>[],
    this.isTv = false,
    super.key,
  });

  final String title;
  final double value;
  final double min;
  final double max;

  /// The granularity of the slider and of one press of a step button.
  final double step;

  final String Function(double value) format;
  final ValueChanged<double> onChanged;

  /// Values worth one press.
  ///
  /// Rendered as one row of equal columns, never a [Wrap]. Five chips at their
  /// natural width overflow a 520 dp dialog and fall onto a second run, and a
  /// second run is a row a remote cannot walk: Left/Right stop at the ends of
  /// the band they are in, so everything below the first line is reachable
  /// only by guessing that Down leads somewhere. Equal columns keep one band
  /// and one arrow walks the lot. The labels are four or five characters, so
  /// there is room to share.
  final List<double> presets;

  final bool isTv;

  @override
  State<PlayerSliderDialog> createState() => _PlayerSliderDialogState();
}

class _PlayerSliderDialogState extends State<PlayerSliderDialog> {
  late double _value = widget.value.clamp(widget.min, widget.max).toDouble();

  /// How close two values have to be to count as the same one, for the preset
  /// that shows as selected. Half a step: the slider lands between presets all
  /// the time, and marking by equality would leave nothing selected at all.
  double get _tolerance => widget.step / 2;

  void _set(double next) {
    final clamped = next.clamp(widget.min, widget.max).toDouble();
    if (clamped == _value) return;
    setState(() => _value = clamped);
    widget.onChanged(clamped);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    // The compact ramp is a phone's, and a television is never it: a 1080p set
    // reports 960x540 dp, so a bare shortest-side test is true on every one.
    final compact = !widget.isTv && size.shortestSide < 600;
    final width = size.width >= 900
        ? 520.0
        : (size.width - 32).clamp(280.0, 360.0).toDouble();
    final divisions = ((widget.max - widget.min) / widget.step).round();

    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 14 : 16,
          vertical: compact ? 16 : 24,
        ),
        child: Material(
          color: HotstarPlayerStyle.background,
          borderRadius: BorderRadius.circular(compact ? 14 : 20),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width),
            child: FocusTraversalGroup(
              policy: ReadingOrderTraversalPolicy(),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 16 : 24,
                  compact ? 12 : 18,
                  compact ? 16 : 24,
                  compact ? 16 : 24,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _header(context, compact: compact),
                    SizedBox(height: compact ? 10 : 20),
                    Text(
                      widget.format(_value),
                      style: TextStyle(
                        color: HotstarPlayerStyle.primaryText,
                        fontSize: compact ? 23 : 28,
                        fontWeight: FontWeight.w600,
                        // So the read-out does not jitter as it is dragged.
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    SizedBox(height: compact ? 14 : 24),
                    _slider(compact: compact, divisions: divisions),
                    if (widget.presets.isNotEmpty) ...<Widget>[
                      SizedBox(height: compact ? 14 : 24),
                      Row(
                        key: kPlayerPresetRowKey,
                        children: <Widget>[
                          for (final preset in widget.presets) ...<Widget>[
                            if (preset != widget.presets.first)
                              SizedBox(width: compact ? 7 : 10),
                            Expanded(
                              child: _PresetChip(
                                label: widget.format(preset),
                                selected: (_value - preset).abs() < _tolerance,
                                compact: compact,
                                onTap: () => _set(preset),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, {required bool compact}) => Row(
    children: <Widget>[
      Expanded(
        child: Text(
          widget.title,
          style: TextStyle(
            color: HotstarPlayerStyle.primaryText,
            fontSize: compact ? 15 : 18,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      _StepButton(
        icon: Icons.close_rounded,
        tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
        compact: compact,
        // Somewhere for the remote to land that is not destructive. The
        // presets are one press away from here by arrow.
        autofocus: widget.isTv,
        onPressed: () => Navigator.of(context).pop(),
      ),
    ],
  );

  Widget _slider({required bool compact, required int divisions}) => Row(
    children: <Widget>[
      _StepButton(
        icon: Icons.remove_rounded,
        tooltip: AppLocalizations.of(context)!.decrease,
        compact: compact,
        onPressed: _value > widget.min ? () => _set(_value - widget.step) : null,
      ),
      SizedBox(width: compact ? 10 : 18),
      Expanded(
        child: SliderTheme(
          data: SliderThemeData(
            trackHeight: compact ? 10 : 18,
            activeTrackColor: Colors.white,
            inactiveTrackColor: Colors.white.withValues(alpha: 0.08),
            thumbColor: Colors.white,
            overlayColor: HotstarPlayerStyle.accent.withValues(alpha: 0.12),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
            trackShape: const RoundedRectSliderTrackShape(),
          ),
          child: CustomSlider(
            value: _value,
            min: widget.min,
            max: widget.max,
            step: widget.step,
            divisions: divisions > 0 ? divisions : null,
            // See this file's header: a read-out on a remote, adjusted by the
            // two buttons either side of it, so Up/Down are never trapped.
            focusable: !widget.isTv,
            onChanged: _set,
          ),
        ),
      ),
      SizedBox(width: compact ? 10 : 18),
      _StepButton(
        icon: Icons.add_rounded,
        tooltip: AppLocalizations.of(context)!.increase,
        compact: compact,
        onPressed: _value < widget.max ? () => _set(_value + widget.step) : null,
      ),
    ],
  );
}

/// One of the dialog's square buttons: the two steps and the close.
class _StepButton extends StatefulWidget {
  const _StepButton({
    required this.icon,
    required this.tooltip,
    required this.compact,
    required this.onPressed,
    this.autofocus = false,
  });

  final IconData icon;
  final String tooltip;
  final bool compact;
  final VoidCallback? onPressed;
  final bool autofocus;

  @override
  State<_StepButton> createState() => _StepButtonState();
}

class _StepButtonState extends State<_StepButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final double side = widget.compact ? 42 : 56;
    return Tooltip(
      message: widget.tooltip,
      child: FocusableActionDetector(
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        child: IconButton(
          onPressed: widget.onPressed,
          autofocus: widget.autofocus,
          icon: Icon(widget.icon, size: widget.compact ? 20 : 24),
          color: HotstarPlayerStyle.primaryText,
          disabledColor: HotstarPlayerStyle.mutedText,
          style: IconButton.styleFrom(
            backgroundColor: _focused
                ? HotstarPlayerStyle.focusFill
                : Colors.white.withValues(alpha: 0.06),
            fixedSize: Size(side, side),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(widget.compact ? 10 : 14),
            ),
          ),
        ),
      ),
    );
  }
}

/// One preset. A focus stop of its own, so a remote reaches every value in the
/// row without going through the slider.
class _PresetChip extends StatefulWidget {
  const _PresetChip({
    required this.label,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  State<_PresetChip> createState() => _PresetChipState();
}

class _PresetChipState extends State<_PresetChip> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final highlight = _focused || _hovered;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.label,
      child: FocusableActionDetector(
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: HotstarPlayerStyle.fastMotionDuration,
            // No width of its own: the row gives every chip an equal share.
            padding: EdgeInsets.symmetric(vertical: widget.compact ? 10 : 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.selected
                  ? HotstarPlayerStyle.accent.withValues(alpha: 0.22)
                  : Colors.white.withValues(alpha: highlight ? 0.12 : 0.06),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                // The accent says "this is the speed you are on"; the ring
                // says "this is the chip the remote is on". Two statements,
                // two colours.
                color: _focused
                    ? HotstarPlayerStyle.focusRing
                    : Colors.transparent,
                width: HotstarPlayerStyle.focusRingWidth,
              ),
            ),
            child: ExcludeSemantics(
              child: Text(
                widget.label,
                textAlign: TextAlign.center,
                maxLines: 1,
                style: TextStyle(
                  color: widget.selected
                      ? HotstarPlayerStyle.primaryText
                      : HotstarPlayerStyle.secondaryText,
                  fontSize: widget.compact ? 13 : 15,
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
