import 'package:flutter/gestures.dart' show GestureBinding, PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import '../search_provider.dart';
import '../../../../shared/widgets/loading_indicator.dart';
import '../../../../shared/widgets/cards_wrapper.dart';

/// The Live TV glyph: three bars of different heights, standing still.
///
/// It was a looping three-controller equalizer. Three `AnimationController`s
/// repeating forever is a frame request forever - on a screen the user is
/// typing into, for a decoration - and it needed its own reduce-motion
/// handling on top, because the framework can shorten an implicit animation
/// but cannot shorten a `repeat()`. A frozen equalizer says "live" just as
/// well and costs nothing, on every device and every motion setting.
class LiveTvIndicator extends StatelessWidget {
  final bool isActive;
  final Color? activeColor;
  final Color? inactiveColor;

  const LiveTvIndicator({
    super.key,
    required this.isActive,
    this.activeColor,
    this.inactiveColor,
  });

  /// Uneven on purpose: three bars of one height read as a pause glyph or a
  /// signal meter, and the tallest in the middle is what makes the shape
  /// read as sound.
  static const List<double> _heights = [6, 11, 8];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isActive
        ? (activeColor ?? Colors.redAccent)
        : (inactiveColor ?? theme.colorScheme.onSurface.withValues(alpha: 0.6));

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final height in _heights)
          Container(
            width: 2,
            height: height,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
      ],
    );
  }
}

/// A custom Scope Pill Switcher with animated sliding fill between states.
class SearchScopeSwitcher extends StatefulWidget {
  final SearchFilter value;
  final FocusNode moviesShowsFocusNode;
  final FocusNode liveTvFocusNode;
  final ValueChanged<SearchFilter> onChanged;

  /// Sized by the caller so the pill can stand beside the search field at
  /// the field's own height instead of below it at its own.
  final double height;

  const SearchScopeSwitcher({
    super.key,
    required this.value,
    required this.moviesShowsFocusNode,
    required this.liveTvFocusNode,
    required this.onChanged,
    this.height = 48,
  });

  @override
  State<SearchScopeSwitcher> createState() => _SearchScopeSwitcherState();
}

class _SearchScopeSwitcherState extends State<SearchScopeSwitcher> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isLive = widget.value == SearchFilter.live;
    final nativeFont = theme.textTheme.bodyLarge?.fontFamily;

    final unselectedTextColor = isDark
        ? Colors.white60
        : theme.colorScheme.onSurfaceVariant;

    // A 2 dp inset all round, so the sliding fill and the two halves keep
    // the same margin inside the track whatever height the caller asks for.
    final innerHeight = widget.height - 4;
    final innerRadius = innerHeight / 2;

    return Container(
      width: 310,
      height: widget.height,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.25,
        ),
        borderRadius: BorderRadius.circular(widget.height / 2),
        border: Border.all(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
        ),
      ),
      child: Stack(
        children: [
          // Sliding indicator pill
          AnimatedAlign(
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutBack,
            alignment: isLive ? Alignment.centerRight : Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: 0.5,
              child: Container(
                margin: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: theme
                      .colorScheme
                      .primary, // Theme primary (Coral in light, Blue in dark)
                  borderRadius: BorderRadius.circular(innerRadius),
                  boxShadow: [
                    BoxShadow(
                      color: theme.colorScheme.primary.withValues(alpha: 0.25),
                      blurRadius: 5,
                      offset: const Offset(0, 1.5),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: CardsWrapper(
                  focusNode: widget.moviesShowsFocusNode,
                  onTap: () => widget.onChanged(SearchFilter.content),
                  borderRadius: BorderRadius.circular(innerRadius),
                  scaleFactor: 1.0,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (_) => widget.onChanged(SearchFilter.content),
                    child: Container(
                      height: innerHeight,
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Transform.translate(
                            offset: const Offset(0, -1.5),
                            child: const Text(
                              '🍿',
                              style: TextStyle(fontSize: 14),
                            ),
                          ),
                          const SizedBox(width: 6),
                          // The pill is a fixed 310 dp wide, so each half has
                          // ~150 dp for its label. At the larger text scales
                          // an unconstrained Text simply overflows the Row;
                          // Flexible lets it use what there is and ellipsise
                          // the rest.
                          Flexible(
                            child: Text(
                              'Movies & Shows',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: nativeFont,
                                fontSize: 13.0,
                                fontWeight: FontWeight.w400,
                                color: !isLive
                                    ? theme.colorScheme.onPrimary
                                    : unselectedTextColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: CardsWrapper(
                  focusNode: widget.liveTvFocusNode,
                  onTap: () => widget.onChanged(SearchFilter.live),
                  borderRadius: BorderRadius.circular(innerRadius),
                  scaleFactor: 1.0,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (_) => widget.onChanged(SearchFilter.live),
                    child: Container(
                      height: innerHeight,
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          LiveTvIndicator(
                            isActive: isLive,
                            inactiveColor: unselectedTextColor.withValues(
                              alpha: 0.6,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              'Live TV',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: nativeFont,
                                fontSize: 13.0,
                                fontWeight: FontWeight.w400,
                                color: isLive
                                    ? theme.colorScheme.onPrimary
                                    : unselectedTextColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The widescreen and desktop search control bar.
class SearchHeaderBar extends ConsumerStatefulWidget {
  final TextEditingController textController;
  final FocusNode searchFocusNode;
  final FocusNode clearButtonFocusNode;
  final FocusNode moviesShowsFocusNode;
  final FocusNode liveTvFocusNode;
  final ValueChanged<String> onSubmitted;
  final ValueChanged<String> onChanged;
  final bool isCompact;

  /// The recents-and-suggestions panel to hang under the field, or null for
  /// no panel. The bar owns where it goes; the caller owns what is in it.
  final Widget? flyout;

  /// Asked for when the user clicks away from the field and its panel, or
  /// presses Escape. The panel's open state is the caller's, because on a
  /// television focus travels INTO the panel and a focus-driven close would
  /// shut it under the user.
  final VoidCallback? onDismissFlyout;

  const SearchHeaderBar({
    super.key,
    required this.textController,
    required this.searchFocusNode,
    required this.clearButtonFocusNode,
    required this.moviesShowsFocusNode,
    required this.liveTvFocusNode,
    required this.onSubmitted,
    required this.onChanged,
    this.isCompact = false,
    this.flyout,
    this.onDismissFlyout,
  });

  /// The field's height, which the scope pill beside it matches.
  static const double kFieldHeight = 48;

  /// How tall the flyout may grow before it scrolls inside itself.
  static const double kFlyoutMaxHeight = 420;

  @override
  ConsumerState<SearchHeaderBar> createState() => _SearchHeaderBarState();
}

class _SearchHeaderBarState extends ConsumerState<SearchHeaderBar> {
  /// Marks the field, so the flyout can measure what it hangs from. The
  /// State's own context covers the whole bar - pill included - and a panel
  /// the width of the bar is not a panel under the field.
  final GlobalKey _fieldKey = GlobalKey();
  final OverlayPortalController _portal = OverlayPortalController();

  @override
  void initState() {
    super.initState();
    // Shown for the bar's whole life; [_buildFlyout] returns an empty box
    // when there is nothing to show. Toggling the controller instead would
    // mean calling show/hide out of a build, which is not allowed.
    _portal.show();
  }

  /// The panel, anchored under the field with MEASURED coordinates.
  ///
  /// A `Positioned` off `localToGlobal`, not a `CompositedTransformFollower`:
  /// a follower hit-tests against the transform from the last composited
  /// frame, which in a real browser leaves the layer's interactive region
  /// away from its paint - rows draw under the field but clicks fall through
  /// to whatever is behind. A `Positioned` hit-tests where it paints.
  void _dismissFlyout() {
    widget.searchFocusNode.unfocus();
    widget.onDismissFlyout?.call();
  }

  Widget _buildFlyout(BuildContext overlayContext) {
    final child = widget.flyout;
    if (child == null) return const SizedBox.shrink();

    final fieldBox = _fieldKey.currentContext?.findRenderObject() as RenderBox?;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (fieldBox == null ||
        overlayBox == null ||
        !fieldBox.attached ||
        !fieldBox.hasSize) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final anchor = fieldBox.localToGlobal(Offset.zero, ancestor: overlayBox);

    return Positioned(
      left: anchor.dx,
      top: anchor.dy + fieldBox.size.height + 8,
      width: fieldBox.size.width,
      child: Listener(
        // The panel has to EAT the wheel notches its own list cannot use.
        // A Scrollable only claims a scroll event when it can actually
        // move, so over a short list the notch falls through to whatever
        // is behind the panel and scrolls that instead.
        onPointerSignal: (event) {
          if (event is! PointerScrollEvent) return;
          GestureBinding.instance.pointerSignalResolver.register(event, (_) {});
        },
        // The overlay child is an element-tree child of this bar, so its
        // scroll notifications would climb out into the page's scrollables.
        // Nothing above needs them.
        child: NotificationListener<ScrollNotification>(
          onNotification: (_) => true,
          // TextFieldTapRegion, not a TapRegion of its own: the panel must
          // count as part of the FIELD's region. EditableText unfocuses on
          // the pointer-DOWN of a tap outside that region, and a real mouse
          // delivers down and up as separate events - so a panel outside it
          // is dismissed on down and the row's tap never lands on up.
          child: TextFieldTapRegion(
            child: Material(
              key: const ValueKey('searchFlyout'),
              elevation: 8,
              clipBehavior: Clip.antiAlias,
              color: theme.colorScheme.surface,
              // The radius goes on the shape alone; Material asserts if it
              // is given borderRadius and shape together.
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.12)
                      : theme.colorScheme.outlineVariant,
                ),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxHeight: SearchHeaderBar.kFlyoutMaxHeight,
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final filter = ref.watch(searchFilterProvider);
    final searchResultsAsync = ref.watch(searchResultsProvider);
    final isCompact = widget.isCompact;
    final isDark = theme.brightness == Brightness.dark;

    // The pill now stands BESIDE the field rather than under it, so the bar
    // needs the width for both. Compact (the home dashboard header) has no
    // pill and keeps its narrow field.
    //
    // The gutter is the bar's own, not the page's: below about 990 dp the
    // field and the pill use the whole 940 they are allowed, and without it
    // the pill's right edge sits hard against the window edge - or against
    // the scrollbar, which is worse.
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: isCompact ? 0 : 24),
      child: Center(
        child: Container(
          constraints: BoxConstraints(maxWidth: isCompact ? 360 : 940),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: OverlayPortal(
                  controller: _portal,
                  overlayChildBuilder: _buildFlyout,
                  child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.escape):
                          _dismissFlyout,
                    },
                    child: GestureDetector(
                      onTap: () {
                        if (!widget.searchFocusNode.hasFocus) {
                          widget.searchFocusNode.requestFocus();
                        }
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        key: _fieldKey,
                        height: SearchHeaderBar.kFieldHeight,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(24),
                          color: theme.colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.3),
                          border: Border.all(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.12)
                                : theme.colorScheme.outlineVariant,
                            width: 1.2,
                          ),
                        ),
                        child: ValueListenableBuilder<TextEditingValue>(
                          valueListenable: widget.textController,
                          builder: (context, value, child) {
                            final isSearching = searchResultsAsync.maybeWhen(
                              data: (state) => state.isLoading,
                              loading: () => true,
                              orElse: () => false,
                            );

                            Widget? suffix;
                            if (isSearching) {
                              suffix = Padding(
                                padding: const EdgeInsets.all(14),
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: AppLoadingIndicator(
                                    color: theme.colorScheme.primary,
                                    constraints: BoxConstraints.tight(
                                      const Size(20, 20),
                                    ),
                                  ),
                                ),
                              );
                            } else if (value.text.isNotEmpty) {
                              suffix = AnimatedBuilder(
                                animation: widget.clearButtonFocusNode,
                                builder: (context, child) {
                                  final isFocused =
                                      widget.clearButtonFocusNode.hasFocus;
                                  return IconButton(
                                    focusNode: widget.clearButtonFocusNode,
                                    icon: Icon(
                                      Icons.clear_rounded,
                                      size: 18,
                                      color: isFocused
                                          ? theme.colorScheme.primary
                                          : (isDark
                                                ? Colors.white70
                                                : theme
                                                      .colorScheme
                                                      .onSurfaceVariant),
                                    ),
                                    style: IconButton.styleFrom(
                                      backgroundColor: isFocused
                                          ? theme.colorScheme.primary
                                                .withValues(alpha: 0.15)
                                          : Colors.transparent,
                                      minimumSize: const Size(32, 32),
                                      padding: EdgeInsets.zero,
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    onPressed: () {
                                      widget.textController.clear();
                                      ref
                                          .read(
                                            searchSuggestionControllerProvider
                                                .notifier,
                                          )
                                          .clear();
                                      ref
                                          .read(searchQueryProvider.notifier)
                                          .set('');
                                      widget.searchFocusNode.requestFocus();
                                    },
                                  );
                                },
                              );
                            }

                            return TextField(
                              controller: widget.textController,
                              focusNode: widget.searchFocusNode,
                              autofocus: false,
                              style: TextStyle(
                                fontSize: 14,
                                color: theme.colorScheme.onSurface,
                              ),
                              textAlignVertical: TextAlignVertical.center,
                              textInputAction: TextInputAction.search,
                              onChanged: widget.onChanged,
                              onSubmitted: widget.onSubmitted,
                              // Fires for taps outside the FIELD's tap region -
                              // and the flyout joins that region (see
                              // [_buildFlyout]), so a click on one of its rows
                              // is not a click away.
                              onTapOutside: (_) => _dismissFlyout(),
                              decoration: InputDecoration(
                                hintText: l10n.searchHint,
                                border: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                filled: false,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 15,
                                ),
                                hintStyle: TextStyle(
                                  fontSize: 13,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                prefixIcon: Icon(
                                  Icons.search_rounded,
                                  size: 20,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                prefixIconConstraints: const BoxConstraints(
                                  minWidth: 46,
                                  minHeight: 48,
                                ),
                                suffixIcon: suffix,
                                suffixIconConstraints: const BoxConstraints(
                                  minWidth: 46,
                                  minHeight: 48,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              if (!isCompact) ...[
                const SizedBox(width: 12),
                SearchScopeSwitcher(
                  value: filter,
                  height: SearchHeaderBar.kFieldHeight,
                  moviesShowsFocusNode: widget.moviesShowsFocusNode,
                  liveTvFocusNode: widget.liveTvFocusNode,
                  onChanged: (val) {
                    ref.read(searchFilterProvider.notifier).set(val);
                    // Re-run the current text against the new scope.
                    final text = widget.textController.text.trim();
                    ref.read(searchQueryProvider.notifier).set(text);
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
