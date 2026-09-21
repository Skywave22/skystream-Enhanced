import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/router/app_router.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../../../core/utils/layout_constants.dart';
import '../../../../shared/widgets/shimmer_placeholder.dart';
import '../../../../shared/widgets/multimedia_card.dart';

import '../controllers/explore_search_controller.dart';
import '../../../search/presentation/search_history_provider.dart';
import '../../../search/presentation/widgets/search_suggestion_row.dart';
import '../../../../shared/widgets/loading_indicator.dart';
import '../../../../core/utils/responsive_breakpoints.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/addons/models/addon_meta.dart' show kAddonItemSource;
import '../../../../shared/widgets/cards_wrapper.dart';
import '../../data/explore_mode_provider.dart';

class ExploreSearchDelegate extends SearchDelegate<void> {
  final FocusNode _firstSuggestionFocusNode = FocusNode();
  final FocusNode _firstResultFocusNode = FocusNode();

  ExploreSearchDelegate()
    : super(
        searchFieldLabel: 'Search movies, tv shows...',
        searchFieldStyle: null,
      ) {
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  /// Moves focus off the search field and into the list below it.
  ///
  /// Global rather than a key callback on the field, because the field
  /// belongs to [SearchDelegate] and cannot be reached to have one attached -
  /// and because an EditableText swallows arrow keys for its own caret, so
  /// directional traversal never sees the press.
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

    return _SearchResultsGrid(
      query: query,
      firstItemFocusNode: _firstResultFocusNode,
    );
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    // No empty-query guard: an empty field is precisely when the recent
    // searches are the only thing there is to show.
    return _SearchSuggestionsList(
      query: query,
      firstItemFocusNode: _firstSuggestionFocusNode,
      onSelectRecent: (val) {
        query = val;
        showResults(context);
      },
    );
  }
}

/// Tall enough for the 76 dp poster plus its breathing room.
const double kExploreSuggestionRowHeight = 92;

class _SearchSuggestionsList extends ConsumerStatefulWidget {
  final String query;
  final FocusNode? firstItemFocusNode;

  /// Runs a recent search. Suggestions navigate straight to a title, but a
  /// recent is a query, so it goes back through the results grid.
  final void Function(String query) onSelectRecent;

  const _SearchSuggestionsList({
    required this.query,
    required this.onSelectRecent,
    this.firstItemFocusNode,
  });

  @override
  ConsumerState<_SearchSuggestionsList> createState() =>
      _SearchSuggestionsListState();
}

class _SearchSuggestionsListState
    extends ConsumerState<_SearchSuggestionsList> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(exploreSearchControllerProvider.notifier)
          .onQueryChanged(widget.query);
    });
  }

  @override
  void didUpdateWidget(covariant _SearchSuggestionsList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) {
      Future.microtask(() {
        if (!context.mounted) return;
        ref
            .read(exploreSearchControllerProvider.notifier)
            .onQueryChanged(widget.query);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final searchState = ref.watch(exploreSearchControllerProvider);
    final history = ref.watch(searchHistoryProvider);
    final isLoading = searchState.isLoading;
    final suggestions = searchState.suggestions;

    final trimmed = widget.query.trim();
    final recents = matchingSearchHistory(
      history,
      trimmed,
      limit: trimmed.isEmpty
          ? kSearchHistoryEmptyFieldLimit
          : kSearchHistoryTypingLimit,
    );
    // With recents above them, the first suggestion is no longer the first
    // thing a D-pad press down from the field should land on.
    final hasRecents = recents.isNotEmpty;

    if (!hasRecents && suggestions.isEmpty) {
      if (isLoading) {
        return Center(
          child: AppLoadingIndicator(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
          ),
        );
      }
      // Nothing typed and nothing searched before: the field's own hint is
      // the whole message, so leave the sheet blank rather than reporting no
      // results for a query the user has not made.
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

    // At most ten recents and ten suggestions, so building the list eagerly
    // costs nothing - and it keeps the recents inside one Semantics group.
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      children: [
        SearchHistorySection(
          queries: recents,
          firstItemFocusNode: hasRecents ? widget.firstItemFocusNode : null,
          onSelect: widget.onSelectRecent,
          onRemove: (query) =>
              ref.read(searchHistoryProvider.notifier).remove(query),
        ),
        for (final (index, item) in suggestions.indexed)
          _buildSuggestionCard(
            context,
            item,
            isFirst: index == 0 && !hasRecents,
            focusNode: (index == 0 && !hasRecents)
                ? widget.firstItemFocusNode
                : null,
          ),
        // Kept below what is already on screen rather than replacing it: the
        // recents should not flicker away on every keystroke.
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

  /// One suggestion, on the shared row face.
  ///
  /// Not a [CardsWrapper] any more. That scaled the whole row 2% on hover,
  /// and a row spans the window - so the growth is a proportion of the
  /// window's width (about 19 dp a side at 1920) while the list's gutter is
  /// a fixed 12, and the wider the window the more of the row was cut off.
  /// Zoom is a POSTER affordance: it works in a rail, where a small card has
  /// room around it. A full-width row highlights instead, which is also what
  /// every other search row in the app does.
  Widget _buildSuggestionCard(
    BuildContext context,
    MultimediaItem item, {
    FocusNode? focusNode,
    bool isFirst = false,
  }) {
    final theme = Theme.of(context);
    final year = item.releaseDate.split('-').first;
    final mediaType = item.mediaType;
    final posterUrl = item.thumbnailImageUrl.isNotEmpty
        ? item.thumbnailImageUrl
        : item.posterImageUrl;

    return SearchSuggestionRow(
      key: ValueKey('explore-suggestion-${item.url}'),
      text: item.title,
      icon: Icons.movie_outlined,
      height: kExploreSuggestionRowHeight,
      focusNode: focusNode,
      isFirst: isFirst,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CachedNetworkImage(
          imageUrl: posterUrl,
          width: 52,
          height: 76,
          fit: BoxFit.cover,
          placeholder: (_, _) => ShimmerPlaceholder(borderRadius: 8),
          errorWidget: (_, _, _) => Container(
            width: 52,
            height: 76,
            color: theme.colorScheme.surfaceContainerHighest,
            alignment: Alignment.center,
            child: const Icon(Icons.movie_outlined, size: 24),
          ),
        ),
      ),
      subtitle: Row(
        children: [
          if (mediaType.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer.withValues(
                  alpha: 0.7,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                mediaType.toUpperCase(),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          if (year.isNotEmpty)
            Text(
              year,
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                fontSize: 13,
              ),
            ),
        ],
      ),
      onTap: () {
        _navigateToItem(
          context,
          item,
          heroTag: 'search_${item.url}',
          isStremioMode:
              ref.read(exploreModeProvider) == ExploreModeType.stremio,
        );
      },
    );
  }
}

void _navigateToItem(
  BuildContext context,
  MultimediaItem item, {
  String? heroTag,
  String? placeholderPoster,
  bool isStremioMode = false,
}) {
  final isAddon =
      item.source == kAddonItemSource ||
      item.url.startsWith('addon:') ||
      isStremioMode ||
      item.url.startsWith('tt') ||
      item.url.startsWith('kitsu:');

  if (isAddon) {
    final String type;
    final String id;
    final String? addonUrl;

    if (item.url.startsWith('addon:')) {
      final parts = item.url.split(':');
      type = parts.length >= 2
          ? parts[1]
          : (item.contentType == MultimediaContentType.series
                ? 'series'
                : 'movie');
      id = parts.length >= 3 ? parts[2] : item.url;
      addonUrl = parts.length > 3 ? parts.sublist(3).join(':') : null;
    } else {
      type = item.contentType == MultimediaContentType.series
          ? 'series'
          : 'movie';
      id = item.url;
      addonUrl = null;
    }

    AddonDetailRoute(
      type: type,
      id: id,
      addonUrl: addonUrl,
    ).push<void>(context);
    return;
  }

  TmdbDetailsRoute(
    movieId: item.id,
    mediaType: item.tmdbMediaType,
    heroTag: heroTag,
    placeholderPoster: placeholderPoster,
    source: item.source,
  ).push<void>(context);
}

class _SearchResultsGrid extends ConsumerStatefulWidget {
  final String query;
  final FocusNode? firstItemFocusNode;

  const _SearchResultsGrid({required this.query, this.firstItemFocusNode});

  @override
  ConsumerState<_SearchResultsGrid> createState() => _SearchResultsGridState();
}

class _SearchResultsGridState extends ConsumerState<_SearchResultsGrid> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _recordSearch();
      ref
          .read(exploreSearchControllerProvider.notifier)
          .fetchResults(widget.query);
    });
  }

  @override
  void didUpdateWidget(covariant _SearchResultsGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) {
      Future.microtask(() {
        if (!context.mounted) return;
        _recordSearch();
        ref
            .read(exploreSearchControllerProvider.notifier)
            .fetchResults(widget.query);
      });
    }
  }

  /// Recorded on the way into the search, not on the way out: a query that
  /// returned nothing is still one the user made and may want back.
  void _recordSearch() {
    unawaited(ref.read(searchHistoryProvider.notifier).add(widget.query));
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      ref.read(exploreSearchControllerProvider.notifier).fetchNextPage();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final searchState = ref.watch(exploreSearchControllerProvider);
    final isLoading = searchState.isLoading;
    final results = searchState.results;
    if (isLoading && results.isEmpty) {
      final screenWidth = MediaQuery.sizeOf(context).width;
      final isDesktop =
          screenWidth > LayoutConstants.exploreCarouselDesktopBreakpoint;
      final maxExtent = isDesktop ? 240.0 : 150.0;
      const childAspectRatio = 0.55;

      return GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: maxExtent,
          childAspectRatio: childAspectRatio,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
        ),
        itemCount: 10,
        itemBuilder: (context, index) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: ShimmerPlaceholder(borderRadius: 12)),
              const SizedBox(height: 8),
              ShimmerPlaceholder.rectangular(height: 14, borderRadius: 4),
            ],
          );
        },
      );
    }

    if (results.isEmpty) {
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

    final screenWidth = MediaQuery.sizeOf(context).width;
    final isDesktop =
        screenWidth > LayoutConstants.exploreCarouselDesktopBreakpoint;
    final maxExtent = isDesktop ? 240.0 : 150.0;
    const childAspectRatio = 0.55;

    return GridView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: maxExtent,
        childAspectRatio: childAspectRatio,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: results.length + (isLoading ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= results.length) {
          return ShimmerPlaceholder(borderRadius: 12);
        }

        final item = results[index];
        final imageUrl = item.posterImageUrl;
        final title = item.title;
        final id = item.id;
        final uniqueTag = 'search_result_${id != 0 ? id : item.url}_$index';

        return MultimediaCard(
          focusNode: index == 0 ? widget.firstItemFocusNode : null,
          imageUrl: imageUrl,
          title: title,
          heroTag: uniqueTag,
          onTap: () {
            _navigateToItem(
              context,
              item,
              heroTag: uniqueTag,
              placeholderPoster: imageUrl,
              isStremioMode:
                  ref.read(exploreModeProvider) == ExploreModeType.stremio,
            );
          },
        );
      },
    );
  }
}
