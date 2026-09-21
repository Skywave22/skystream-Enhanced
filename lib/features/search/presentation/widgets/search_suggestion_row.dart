import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../l10n/generated/app_localizations.dart';

/// Whether the caret is currently in a text field.
///
/// Used by the search delegates, which cannot attach a key callback to the
/// field [SearchDelegate] builds for them and so watch the keyboard globally
/// instead. They have to know whether a press belongs to the field before
/// they act on it.
///
/// The obvious test - `primaryFocus.context.widget is EditableText` - is
/// always false. [EditableText] builds the `Focus` that owns its node as a
/// DESCENDANT of itself, so the focused context's widget is that `Focus`,
/// and the [EditableText] is above it. Walking up is what finds it.
bool searchFieldHoldsFocus() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  if (context.widget is EditableText) return true;
  return context.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// One row of a search panel: a recent search, or a network suggestion.
///
/// The single row face for every search surface - the search tab's body on a
/// phone, its flyout on a desktop, and the home and explore delegates. They
/// used to disagree: bordered cards with a shadow on the search tab, plain
/// `ListTile`s on home, poster cards on explore. Three answers to "what does
/// a suggestion look like" is two too many.
///
/// Flat on purpose. A row sits inside a panel that already has the border
/// and the shadow, or on a page that provides the ground; framing each row
/// as well frames it twice.
///
/// Carries the D-pad wiring the television layout needs, which the row face
/// this is modelled on did not have to: the body and the trailing button are
/// separate focus stops, so a remote can reach "run this search" and "forget
/// this search" as two different targets on one line.
class SearchSuggestionRow extends StatefulWidget {
  final String text;

  /// The leading glyph. A clock marks a recent, a magnifier a suggestion -
  /// which is the only thing distinguishing the two groups, since they carry
  /// no section labels. Ignored when [leading] is given.
  final IconData icon;

  /// Replaces the glyph - explore's rows put a poster here, because a title
  /// in a film catalogue is recognised by its artwork faster than by its
  /// name.
  final Widget? leading;

  /// A second line under [text]. Explore uses it for the media-type badge
  /// and the year.
  final Widget? subtitle;

  final VoidCallback onTap;

  /// The right-hand button, or null for a row that has none.
  final IconData? trailingIcon;
  final VoidCallback? onTrailingTap;

  /// Names the trailing button for a screen reader. A bare cross in a list
  /// of searches does not say which one it removes.
  final String? trailingSemanticLabel;

  /// Set on the first row, so a D-pad press down from the search field lands
  /// here.
  final FocusNode? focusNode;

  /// Where an arrow-up from the first row should go. Null leaves the key to
  /// the default traversal.
  final VoidCallback? onFocusUp;

  final bool isFirst;

  /// Overrides [kHeight] for a row carrying more than one line, such as one
  /// with a poster in it.
  final double? height;

  const SearchSuggestionRow({
    super.key,
    required this.text,
    required this.icon,
    required this.onTap,
    this.leading,
    this.subtitle,
    this.height,
    this.trailingIcon,
    this.onTrailingTap,
    this.trailingSemanticLabel,
    this.focusNode,
    this.onFocusUp,
    this.isFirst = false,
  });

  /// The row's height. Comfortably over the 48 dp minimum touch target, and
  /// the same whether or not a row has a trailing button, so a list of them
  /// reads as evenly spaced lines.
  static const double kHeight = 52;

  @override
  State<SearchSuggestionRow> createState() => _SearchSuggestionRowState();
}

class _SearchSuggestionRowState extends State<SearchSuggestionRow> {
  bool _isBodyHovered = false;
  bool _isButtonHovered = false;

  late final FocusNode _bodyNode;
  final FocusNode _buttonNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _bodyNode = widget.focusNode ?? FocusNode();
    _bodyNode.addListener(_onFocusChange);
    _buttonNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    // The node is only ours to dispose when we made it; a caller's node
    // outlives this row.
    if (widget.focusNode == null) {
      _bodyNode.dispose();
    } else {
      if (_bodyNode.hasFocus) _bodyNode.unfocus();
      _bodyNode.removeListener(_onFocusChange);
    }
    _buttonNode.dispose();
    super.dispose();
  }

  /// Runs a row action after letting go of the focus it holds.
  ///
  /// Acting while focused breaks on every surface that shows these rows.
  /// Tearing down a focused row bounces focus back to the search field, and
  /// "the field gained focus" means "show the suggestions" to both the search
  /// tab and Flutter's own [SearchDelegate] - so the panel this action was
  /// meant to close reopened on top of the results, a frame later.
  ///
  /// Dropping focus first, and acting once the manager has settled, means the
  /// row is already unfocused when it is disposed and there is nothing to
  /// bounce.
  void _activate(VoidCallback action) {
    _bodyNode.unfocus();
    _buttonNode.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) => action());
  }

  bool _handleUp() {
    if (!widget.isFirst || widget.onFocusUp == null) return false;
    widget.onFocusUp!.call();
    return true;
  }

  static bool _isSelect(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.space;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final hasTrailing =
        widget.trailingIcon != null && widget.onTrailingTap != null;

    final isBodyHighlighted = _isBodyHovered || _bodyNode.hasFocus;
    final isButtonHighlighted = _isButtonHovered || _buttonNode.hasFocus;

    final highlightColor = isDark
        ? const Color(0xFF1F80E0)
        : theme.colorScheme.primary;
    final rowHighlightBg = highlightColor.withValues(
      alpha: isDark ? 0.22 : 0.10,
    );
    final buttonChipBg = highlightColor.withValues(alpha: isDark ? 0.45 : 0.22);
    final iconColor = theme.colorScheme.onSurfaceVariant;

    // A poster is its own left edge. The 12 dp inset that sits well under a
    // 20 dp glyph reads as a gap when the row starts with artwork, because
    // the highlight then opens with a strip of empty colour before anything.
    final leadingInset = widget.leading != null ? 6.0 : 12.0;

    return SizedBox(
      height: widget.height ?? SearchSuggestionRow.kHeight,
      // ONE fill, across the whole row.
      //
      // The body and the button used to tint their own halves, which on a
      // row whose body is most of its width drew a bar that stopped dead
      // before the button - it read as text selected in a document rather
      // than as a row being pointed at. The row is what the user is on; the
      // button, when it is the target, says so with a chip inside it.
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeInOut,
        decoration: BoxDecoration(
          color: (isBodyHighlighted || isButtonHighlighted)
              ? rowHighlightBg
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Expanded(
              child: Focus(
                focusNode: _bodyNode,
                onKeyEvent: (node, event) {
                  if (event is! KeyDownEvent) return KeyEventResult.ignored;
                  if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
                      _handleUp()) {
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
                      hasTrailing) {
                    _buttonNode.requestFocus();
                    return KeyEventResult.handled;
                  }
                  if (_isSelect(event.logicalKey)) {
                    _activate(widget.onTap);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: MouseRegion(
                  onEnter: (_) => setState(() => _isBodyHovered = true),
                  onExit: (_) => setState(() => _isBodyHovered = false),
                  child: GestureDetector(
                    onTap: widget.onTap,
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: EdgeInsets.only(left: leadingInset, right: 12),
                      child: Row(
                        children: [
                          widget.leading ??
                              Icon(
                                widget.icon,
                                size: 20,
                                color: isBodyHighlighted
                                    ? highlightColor
                                    : iconColor,
                              ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.text,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: theme.colorScheme.onSurface,
                                  ),
                                ),
                                if (widget.subtitle != null) ...[
                                  const SizedBox(height: 6),
                                  widget.subtitle!,
                                ],
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
            if (hasTrailing)
              Focus(
                focusNode: _buttonNode,
                onKeyEvent: (node, event) {
                  if (event is! KeyDownEvent) return KeyEventResult.ignored;
                  if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
                      _handleUp()) {
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                    _bodyNode.requestFocus();
                    return KeyEventResult.handled;
                  }
                  if (_isSelect(event.logicalKey)) {
                    _activate(widget.onTrailingTap!);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: MouseRegion(
                  onEnter: (_) => setState(() => _isButtonHovered = true),
                  onExit: (_) => setState(() => _isButtonHovered = false),
                  child: GestureDetector(
                    onTap: widget.onTrailingTap,
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Center(
                        widthFactor: 1,
                        // A chip, not a second bar: it says "the remote is on
                        // the cross, not on the row" without cutting the row's
                        // own highlight in two.
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          curve: Curves.easeInOut,
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: isButtonHighlighted
                                ? buttonChipBg
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            widget.trailingIcon,
                            size: 18,
                            semanticLabel: widget.trailingSemanticLabel,
                            color: isButtonHighlighted
                                ? highlightColor
                                : iconColor,
                          ),
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

/// The recents block that sits above a suggestion list.
///
/// Returns nothing at all when [queries] is empty, so a caller can drop it
/// into a column without guarding.
class SearchHistorySection extends StatelessWidget {
  final List<String> queries;
  final void Function(String query) onSelect;
  final void Function(String query) onRemove;
  final FocusNode? firstItemFocusNode;
  final VoidCallback? onFocusUp;

  const SearchHistorySection({
    super.key,
    required this.queries,
    required this.onSelect,
    required this.onRemove,
    this.firstItemFocusNode,
    this.onFocusUp,
  });

  @override
  Widget build(BuildContext context) {
    if (queries.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;

    // No visible section label - the clock glyph is what marks these as
    // recents. Screen readers get the grouping from here instead.
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: l10n.recentSearches,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (index, query) in queries.indexed)
            SearchSuggestionRow(
              key: ValueKey('search-history-$query'),
              text: query,
              icon: Icons.history_rounded,
              focusNode: index == 0 ? firstItemFocusNode : null,
              isFirst: index == 0,
              onFocusUp: onFocusUp,
              trailingIcon: Icons.close_rounded,
              trailingSemanticLabel: l10n.removeFromSearchHistory(query),
              onTap: () => onSelect(query),
              onTrailingTap: () => onRemove(query),
            ),
        ],
      ),
    );
  }
}
