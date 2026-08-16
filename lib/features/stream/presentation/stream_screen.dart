import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/providers/device_info_provider.dart';
import '../../../core/router/app_router.dart';
import '../../../core/utils/image_fallbacks.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/thumbnail_error_placeholder.dart';
import '../data/stream_browser_provider.dart';
import 'stream_source_picker.dart';

class StreamScreen extends ConsumerWidget {
  const StreamScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(streamBrowserProvider);
    final l10n = AppLocalizations.of(context)!;
    final profile = ref.watch(deviceProfileProvider).asData?.value;
    final isWidescreen = profile?.isTv == true || context.isTabletOrLarger;

    final body = DefaultTabController(
      length: 2,
      initialIndex: state.tabIndex,
      child: Builder(
        builder: (context) {
          final controller = DefaultTabController.of(context);
          controller.addListener(() {
            if (!controller.indexIsChanging) {
              ref.read(streamBrowserProvider.notifier).setTab(controller.index);
            }
          });
          return Column(
            children: [
              TabBar(
                tabs: [
                  Tab(text: l10n.movie),
                  Tab(text: l10n.tvShow),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _MediaGrid(itemsAsync: state.movies),
                    _MediaGrid(itemsAsync: state.series),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );

    if (isWidescreen) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Container(
                height: LayoutConstants.dashboardHeaderHeight,
                padding: const EdgeInsets.symmetric(
                  horizontal: LayoutConstants.dashboardContentPadding,
                ),
                alignment: Alignment.centerLeft,
                child: Text(
                  'Stream',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ),
            ),
            Expanded(child: body),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Stream')),
      body: body,
    );
  }
}

class _MediaGrid extends ConsumerWidget {
  final AsyncValue<List<MultimediaItem>> itemsAsync;
  const _MediaGrid({required this.itemsAsync});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return itemsAsync.when(
      data: (items) {
        if (items.isEmpty) {
          return const Center(child: Text('No TMDB results found.'));
        }
        final width = MediaQuery.sizeOf(context).width;
        final crossAxisCount = (width / 160).floor().clamp(2, 8);
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: 0.62,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return _StreamPosterCard(item: item);
          },
        );
      },
      loading: () => const Center(child: AppLoadingIndicator()),
      error: (error, _) => Center(child: Text(error.toString())),
    );
  }
}

class _StreamPosterCard extends ConsumerWidget {
  final MultimediaItem item;
  const _StreamPosterCard({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final mediaType = item.contentType == MultimediaContentType.series ||
            item.contentType == MultimediaContentType.anime
        ? 'tv'
        : 'movie';
    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: () => TmdbDetailsRoute(
          movieId: item.tmdbId ?? item.id,
          mediaType: mediaType,
          placeholderPoster: item.posterUrl,
        ).push<void>(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CachedNetworkImage(
                    imageUrl: AppImageFallbacks.poster(
                          item.posterUrl,
                          label: item.title,
                        ) ??
                        '',
                    fit: BoxFit.cover,
                    errorWidget: (_, _, _) => ThumbnailErrorPlaceholder(
                      label: item.title,
                    ),
                  ),
                  Positioned(
                    left: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        mediaType == 'tv' ? 'TV' : 'Movie',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => StreamSourcePicker.open(context, ref, item),
                      icon: const Icon(Icons.play_arrow_rounded, size: 18),
                      label: const Text('Play'),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
