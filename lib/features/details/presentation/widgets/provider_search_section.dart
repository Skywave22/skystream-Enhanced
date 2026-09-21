import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/router/app_router.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/core/utils/image_fallbacks.dart';
import 'package:skystream/features/search/presentation/search_provider.dart';

import '../../../../shared/widgets/cards_wrapper.dart';

import '../../../../core/utils/layout_constants.dart';
import '../../../../shared/widgets/shimmer_placeholder.dart';
import '../../../../shared/widgets/thumbnail_error_placeholder.dart';
import '../../../../shared/widgets/loading_indicator.dart';

import 'package:skystream/l10n/generated/app_localizations.dart';

import 'source_section_card.dart';

part 'provider_search_section.g.dart';

// Delegates to the shared searchAllProviders() function — no duplicated
// fan-out, mapping, or filtering logic.
@riverpod
Stream<SearchAggregateState> providerSearch(Ref ref, String query) {
  ref.watch(extensionManagerProvider);
  final manager = ref.read(extensionManagerProvider.notifier);

  var cancelled = false;
  ref.onDispose(() => cancelled = true);

  return searchAllProviders(
    ref,
    query,
    manager,
    filter: SearchFilter.content,
    isCancelled: () => cancelled,
  );
}

class ProviderSearchSection extends ConsumerStatefulWidget {
  /// Height of the poster cards themselves.
  static const double cardHeight = 140;

  /// Room above and below the cards for a card's hover and focus growth.
  ///
  /// [CardsWrapper] scales a card to 1.03 when a pointer is over it and paints
  /// its focus ring OUTSIDE the card's own box, and the rail's viewport clips -
  /// so with the viewport sized to the cards exactly, the top and bottom of a
  /// hovered card were sliced off. 8 dp is the figure the app's other rails
  /// reserve for this, and the one [CardFocusAffordance]'s glow blur is tuned
  /// against.
  static const double growthHeadroom = 8;

  /// Strip reserved beneath the cards for the scrollbar track, so it stops
  /// painting over the artwork it describes.
  static const double scrollbarGutter = 12;

  /// Space the rail already leaves below the last pixel of its cards.
  ///
  /// A caller spacing this section from the next group subtracts this, or the
  /// gap the eye sees here comes out this much larger than everywhere else -
  /// which is exactly how the page ended up with 32, 36 and 24 between three
  /// groups that were all meant to be the same.
  static const double bottomInset = growthHeadroom + scrollbarGutter;

  /// Viewport height: cards, the growth headroom on both sides, and the strip.
  /// Every state of this block uses it, including the empty and loading ones,
  /// so the section does not change height as results arrive.
  static const double railHeight =
      cardHeight + growthHeadroom * 2 + scrollbarGutter;

  final String query;
  final bool compact;
  final bool showHeader;
  final String? parentMediaType; // 'movie' or 'tv'
  final int? tmdbId;
  final String? imdbId;

  const ProviderSearchSection({
    super.key,
    required this.query,
    this.compact = false,
    this.showHeader = true,
    this.parentMediaType,
    this.tmdbId,
    this.imdbId,
  });

  @override
  ConsumerState<ProviderSearchSection> createState() =>
      _ProviderSearchSectionState();
}

class _ProviderSearchSectionState extends ConsumerState<ProviderSearchSection> {
  late final ScrollController _scrollController;
  bool _canScrollRight = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _scrollController.addListener(() {
      final canRight =
          _scrollController.hasClients &&
          _scrollController.position.extentAfter > 10;
      if (canRight != _canScrollRight) {
        setState(() => _canScrollRight = canRight);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollBy(double offset) {
    if (!_scrollController.hasClients) return;
    final target = (_scrollController.offset + offset).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.query.isEmpty) return const SizedBox.shrink();

    final plugins = ref.watch(extensionManagerProvider);
    final searchAsync = ref.watch(providerSearchProvider(widget.query));

    Widget content;
    if (plugins.isEmpty) {
      content = Container(
        height: ProviderSearchSection.railHeight,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(LayoutConstants.spacingMd),
        child: Text(
          AppLocalizations.of(context)!.noPluginsInstalled,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 14,
          ),
        ),
      );
    } else {
      content = searchAsync.when(
        data: (state) {
          final allItems = <Map<String, dynamic>>[];
          for (final pResult in state.results) {
            for (final item in pResult.results) {
              allItems.add({
                'item': item,
                'providerName': pResult.providerName,
              });
            }
          }

          if (allItems.isEmpty) {
            if (state.isLoading) {
              return const SizedBox(
                height: ProviderSearchSection.railHeight,
                child: Center(
                  child: AppLoadingIndicator(
                    constraints: BoxConstraints(
                      minWidth: 24,
                      minHeight: 24,
                      maxWidth: 24,
                      maxHeight: 24,
                    ),
                  ),
                ),
              );
            }
            return Container(
              height: ProviderSearchSection.railHeight,
              alignment: Alignment.center,
              padding: const EdgeInsets.all(LayoutConstants.spacingMd),
              child: Text(
                AppLocalizations.of(context)!.noResultsFound,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            );
          }

          return RepaintBoundary(
            child: SizedBox(
              height: ProviderSearchSection.railHeight,
              child: NotificationListener<ScrollMetricsNotification>(
                onNotification: (notification) {
                  if (notification.metrics.axis == Axis.horizontal) {
                    final canRight = notification.metrics.extentAfter > 10;
                    if (canRight != _canScrollRight) {
                      setState(() => _canScrollRight = canRight);
                    }
                  }
                  return false;
                },
                child: ShaderMask(
                  shaderCallback: (Rect bounds) {
                    if (!_canScrollRight) {
                      return const LinearGradient(
                        colors: [Colors.black, Colors.black],
                      ).createShader(bounds);
                    }
                    return const LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [Colors.black, Colors.black, Colors.transparent],
                      stops: [0.0, 0.88, 1.0],
                    ).createShader(bounds);
                  },
                  blendMode: BlendMode.dstIn,
                  child: Scrollbar(
                    controller: _scrollController,
                    child: ListView.separated(
                      controller: _scrollController,
                      clipBehavior: Clip.hardEdge,
                      scrollDirection: Axis.horizontal,
                      // `top` and `bottom` on a HORIZONTAL list inset the
                      // CROSS axis: the cards keep _cardHeight, sit clear of
                      // both edges by ProviderSearchSection.growthHeadroom so hovering one does not
                      // crop it, and the scrollbar track gets the strip below.
                      padding: widget.compact
                          ? const EdgeInsets.fromLTRB(
                              0,
                              ProviderSearchSection.growthHeadroom,
                              0,
                              ProviderSearchSection.growthHeadroom +
                                  ProviderSearchSection.scrollbarGutter,
                            )
                          : const EdgeInsets.fromLTRB(
                              LayoutConstants.spacingMd,
                              ProviderSearchSection.growthHeadroom,
                              LayoutConstants.spacingMd,
                              ProviderSearchSection.growthHeadroom +
                                  ProviderSearchSection.scrollbarGutter,
                            ),
                      itemCount: allItems.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(width: LayoutConstants.spacingSm),
                      itemBuilder: (context, index) {
                        final data = allItems[index];
                        final item = data['item'] as MultimediaItem;
                        final providerName = data['providerName'] as String;

                        return CardsWrapper(
                          onTap: () {
                            // Enrich item with provider, content type, and metadata IDs before navigation
                            final enrichedItem = item.copyWith(
                              provider: providerName,
                              contentType: widget.parentMediaType != null
                                  ? MultimediaItem.parseContentType(
                                      widget.parentMediaType,
                                    )
                                  : item.contentType,
                              tmdbId: widget.tmdbId ?? item.tmdbId,
                              imdbId: widget.imdbId ?? item.imdbId,
                            );
                            DetailsRoute(
                              $extra: DetailsRouteExtra(item: enrichedItem),
                            ).push<void>(context);
                          },
                          child: SizedBox(
                            width: 220,
                            child: Card(
                              elevation: 0,
                              margin: EdgeInsets.zero,
                              color: Theme.of(context).colorScheme.surface,
                              clipBehavior: Clip.antiAlias,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(
                                  color: Theme.of(context).colorScheme.onSurface
                                      .withValues(alpha: 0.3),
                                ),
                              ),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 90,
                                    height: double.infinity,
                                    child: CachedNetworkImage(
                                      imageUrl:
                                          AppImageFallbacks.poster(
                                            item.posterUrl,
                                            label: item.title,
                                          ) ??
                                          '',
                                      fit: BoxFit.cover,
                                      placeholder: (_, _) =>
                                          ShimmerPlaceholder(borderRadius: 8),
                                      errorWidget: (_, _, _) =>
                                          const ThumbnailErrorPlaceholder(),
                                    ),
                                  ),
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.all(10.0),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Text(
                                            item.title,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.bold,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurface,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .primaryContainer,
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              providerName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onPrimaryContainer,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          );
        },
        loading: () => const SizedBox(
          height: ProviderSearchSection.railHeight,
          child: Center(
            child: AppLoadingIndicator(
              constraints: BoxConstraints(
                minWidth: 24,
                minHeight: 24,
                maxWidth: 24,
                maxHeight: 24,
              ),
            ),
          ),
        ),
        error: (err, _) => Padding(
          padding: const EdgeInsets.all(LayoutConstants.spacingMd),
          child: Text(
            AppLocalizations.of(context)!.errorPrefix(err.toString()),
          ),
        ),
      );
    }

    return SourceSectionCard(
      icon: Icons.extension,
      title: AppLocalizations.of(context)!.availableSources,
      compact: widget.compact,
      showHeader: widget.showHeader,
      minHeight: widget.compact ? null : 180,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _HeaderArrowButton(
            icon: Icons.arrow_back_ios_new,
            onTap: () => _scrollBy(-300),
          ),
          const SizedBox(width: 4),
          _HeaderArrowButton(
            icon: Icons.arrow_forward_ios,
            onTap: () => _scrollBy(300),
          ),
        ],
      ),
      child: content,
    );
  }
}

class _HeaderArrowButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _HeaderArrowButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CardsWrapper(
      scaleFactor: 1.05,
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.4,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 12, color: theme.colorScheme.onSurface),
      ),
    );
  }
}
