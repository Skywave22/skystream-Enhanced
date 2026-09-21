import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/extensions/extension_manager.dart';
import '../../../../core/extensions/base_provider.dart';
import '../../../../core/utils/image_fallbacks.dart';
import '../../../search/presentation/search_history_provider.dart';
import '../../../search/presentation/search_provider.dart';
import '../../../search/presentation/widgets/search_suggestion_row.dart';

import 'package:skystream/shared/widgets/multimedia_card.dart';

import '../../../../shared/widgets/loading_indicator.dart';
import '../../../../core/utils/responsive_breakpoints.dart';

class HomeSearchDelegate extends SearchDelegate<void> {
  final String? initialQuery;

  /// Where a D-pad press down from the search field lands.
  final FocusNode _firstSuggestionFocusNode = FocusNode();
  final FocusNode _firstResultFocusNode = FocusNode();

  HomeSearchDelegate({this.initialQuery})
    : super(
        searchFieldLabel: 'Search movies, series...',
        searchFieldStyle: null,
      ) {
    if (initialQuery != null) {
      query = initialQuery!;
    }
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  /// Moves focus off the search field and into the list below it.
  ///
  /// A global handler rather than a key callback on the field, because the
  /// field belongs to [SearchDelegate] and cannot be reached to have one
  /// attached. It has to be global for a second reason too: an EditableText
  /// swallows arrow keys for its own cursor, so directional traversal never
  /// sees the press and focus would stay in the field forever.
  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.arrowDown) {
      return false;
    }
    if (!searchFieldHoldsFocus()) return false;

    if (_firstSuggestionFocusNode.canRequestFocus) {
      _firstSuggestionFocusNode.requestFocus();
      return true;
    }
    if (_firstResultFocusNode.canRequestFocus) {
      _firstResultFocusNode.requestFocus();
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _firstSuggestionFocusNode.dispose();
    _firstResultFocusNode.dispose();
    super.dispose();
  }

  @override
  ThemeData appBarTheme(BuildContext context) {
    final theme = Theme.of(context);
    return theme.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
        iconTheme: IconThemeData(color: theme.colorScheme.onSurface),
        toolbarHeight: 70,
      ),
      inputDecorationTheme: InputDecorationTheme(
        hintStyle: TextStyle(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
        ),
        border: InputBorder.none,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: theme.colorScheme.primary,
        selectionColor: theme.colorScheme.primary.withValues(alpha: 0.3),
      ),
      textTheme: theme.textTheme.copyWith(
        titleMedium: TextStyle(
          color: theme.colorScheme.onSurface,
          fontSize: 18,
        ),
      ),
    );
  }

  @override
  List<Widget>? buildActions(BuildContext context) {
    return [
      if (query.isNotEmpty)
        IconButton(
          icon: const Icon(Icons.clear),
          onPressed: () {
            query = '';
            showSuggestions(context);
          },
        ),
      const SizedBox(width: 8),
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back_rounded),
      onPressed: () => close(context, null),
    );
  }

  @override
  Widget buildResults(BuildContext context) {
    if (query.isEmpty) return const SizedBox.shrink();
    return _HomeSearchResults(
      query: query,
      firstItemFocusNode: _firstResultFocusNode,
    );
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    // No empty-query guard: an empty field is precisely when the recent
    // searches are the only thing there is to show.
    return _HomeSearchSuggestions(
      query: query,
      firstItemFocusNode: _firstSuggestionFocusNode,
      onSelect: (val) {
        query = val;
        showResults(context);
      },
    );
  }
}

class _HomeSearchSuggestions extends ConsumerStatefulWidget {
  final String query;
  final void Function(String) onSelect;
  final FocusNode? firstItemFocusNode;

  const _HomeSearchSuggestions({
    required this.query,
    required this.onSelect,
    this.firstItemFocusNode,
  });

  @override
  ConsumerState<_HomeSearchSuggestions> createState() =>
      _HomeSearchSuggestionsState();
}

class _HomeSearchSuggestionsState
    extends ConsumerState<_HomeSearchSuggestions> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(searchSuggestionControllerProvider.notifier)
          .onQueryChanged(widget.query);
    });
  }

  @override
  void didUpdateWidget(covariant _HomeSearchSuggestions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) {
      Future.microtask(() {
        if (!context.mounted) return;
        ref
            .read(searchSuggestionControllerProvider.notifier)
            .onQueryChanged(widget.query);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final searchState = ref.watch(searchSuggestionControllerProvider);
    final history = ref.watch(searchHistoryProvider);
    final isLoading = searchState.isLoading;

    final trimmed = widget.query.trim();
    // An empty field gets the full recents list; once the user is typing,
    // only a few, because the suggestions underneath are what they are
    // typing towards.
    final recents = matchingSearchHistory(
      history,
      trimmed,
      limit: trimmed.isEmpty
          ? kSearchHistoryEmptyFieldLimit
          : kSearchHistoryTypingLimit,
    );
    final suggestions = withoutDuplicatedHistory(
      searchState.suggestions,
      recents,
    );

    if (recents.isEmpty && suggestions.isEmpty && !isLoading) {
      // Nothing typed and nothing searched before: the field's own hint is
      // the whole message, so leave the sheet blank rather than telling the
      // user there are no results for a query they have not made.
      if (trimmed.isEmpty) return const SizedBox.shrink();
      return Center(
        child: Text(
          'No results found',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface
                .withValues(alpha: 0.5),
          ),
        ),
      );
    }

    // At most ten recents and ten suggestions, so the whole list is cheap to
    // build eagerly - and that keeps the recents inside one Semantics group.
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      children: [
        SearchHistorySection(
          queries: recents,
          // The first row overall takes the node, whether it is a recent or
          // - with no history - the first suggestion.
          firstItemFocusNode: recents.isNotEmpty
              ? widget.firstItemFocusNode
              : null,
          onSelect: widget.onSelect,
          onRemove: (query) =>
              ref.read(searchHistoryProvider.notifier).remove(query),
        ),
        for (final (index, suggestion) in suggestions.indexed)
          SearchSuggestionRow(
            key: ValueKey('search-suggestion-$suggestion'),
            text: suggestion,
            icon: Icons.search_rounded,
            focusNode: (index == 0 && recents.isEmpty)
                ? widget.firstItemFocusNode
                : null,
            trailingIcon: Icons.north_west_rounded,
            onTap: () => widget.onSelect(suggestion),
            onTrailingTap: () => widget.onSelect(suggestion),
          ),
        // Kept below the recents rather than replacing the screen: the
        // recents are already on the glass and should not flicker away every
        // time a keystroke starts a new suggestion fetch.
        if (isLoading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: AppLoadingIndicator(
                color: Theme.of(context).colorScheme.primary
                    .withValues(alpha: 0.5),
              ),
            ),
          ),
      ],
    );
  }
}

class _HomeSearchResults extends ConsumerStatefulWidget {
  final String query;
  final FocusNode? firstItemFocusNode;

  const _HomeSearchResults({required this.query, this.firstItemFocusNode});

  @override
  ConsumerState<_HomeSearchResults> createState() => _HomeSearchResultsState();
}

class _HomeSearchResultsState extends ConsumerState<_HomeSearchResults> {
  bool isLoading = true;
  ProviderSearchResult? result;

  @override
  void initState() {
    super.initState();
    _performSearch();
  }

  @override
  void didUpdateWidget(covariant _HomeSearchResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) {
      _performSearch();
    }
  }

  Future<void> _performSearch() async {
    // Recorded on the way into the search, not on the way out: a query that
    // returned nothing is still one the user made and may want back.
    unawaited(ref.read(searchHistoryProvider.notifier).add(widget.query));

    setState(() {
      isLoading = true;
      result = null;
    });

    final SkyStreamProvider? provider = ref.read(activeProviderProvider);
    if (provider == null) {
      if (mounted) setState(() => isLoading = false);
      return;
    }

    try {
      final rawResults = await provider.search(widget.query);
      if (mounted) {
        setState(() {
          isLoading = false;
          result = ProviderSearchResult(
            providerId: provider.packageName,
            providerName: provider.name,
            results: rawResults.toList(),
          );
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(child: AppLoadingIndicator());
    }

    if (result == null || result!.results.isEmpty) {
      // Size question, asked of the size: a 960 dp television clears the
      // tablet breakpoint like any other big window.
      final isWidescreen = context.isTabletOrLarger;
      final imageWidth = isWidescreen ? 320.0 : 200.0;
      final nativeFont = Theme.of(context).textTheme.bodyLarge?.fontFamily;

      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'No Results Found',
              style: TextStyle(
                fontFamily: nativeFont,
                fontSize: 16.0,
                fontWeight: FontWeight.w400,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Image.asset(
              'assets/images/no_results.png',
              fit: BoxFit.contain,
              width: imageWidth,
              // Source is 1613x1929 — 11.9 MB decoded — for an illustration
              // shown at 320 logical px at most. 640 covers 2x density.
              cacheWidth: 640,
              errorBuilder: (context, error, stackTrace) =>
                  const SizedBox.shrink(),
            ),
          ],
        ),
      );
    }

    final isLarge = MediaQuery.of(context).size.width > 600;
    final maxExtent = isLarge ? 200.0 : 130.0;

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: maxExtent,
        childAspectRatio: 2 / 3.2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 16,
      ),
      itemCount: result!.results.length,
      itemBuilder: (context, index) {
        final item = result!.results[index];
        final uniqueTag = 'search_${result!.providerId}_${item.url}_$index';

        return MultimediaCard(
          key: ValueKey(item.url),
          focusNode: index == 0 ? widget.firstItemFocusNode : null,
          imageUrl: AppImageFallbacks.poster(item.posterUrl, label: item.title),
          title: item.title,
          heroTag: uniqueTag,
          onTap: () =>
              DetailsRoute($extra: DetailsRouteExtra(item: item))
                  .push<void>(context),
        );
      },
    );
  }
}
