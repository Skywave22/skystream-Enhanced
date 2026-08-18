import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/addons/models/addon_meta.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../sources/presentation/addon_sources_sheet.dart';
import '../../sources/presentation/source_sheet_widgets.dart';
import 'addon_catalog_providers.dart';

/// Detail page for a catalog entry coming from a Stremio add-on.
///
/// Everything on this page is add-on powered: metadata comes from a `meta`
/// add-on and Play/Download open the add-on sources sheet. No plugin is
/// involved anywhere in this flow.
class AddonDetailScreen extends ConsumerStatefulWidget {
  final String type;
  final String id;
  final String? addonId;

  const AddonDetailScreen({
    super.key,
    required this.type,
    required this.id,
    this.addonId,
  });

  @override
  ConsumerState<AddonDetailScreen> createState() => _AddonDetailScreenState();
}

class _AddonDetailScreenState extends ConsumerState<AddonDetailScreen> {
  int? _selectedSeason;

  @override
  Widget build(BuildContext context) {
    final metaAsync = ref.watch(
      addonMetaDetailsProvider(
        widget.type,
        widget.id,
        preferredAddonId: widget.addonId,
      ),
    );

    return Scaffold(
      body: metaAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorBody(message: error.toString()),
        data: (meta) {
          if (meta == null) {
            return const _ErrorBody(
              message:
                  'No installed add-on could describe this title. Install a '
                  'metadata add-on such as Cinemeta.',
            );
          }
          return _Body(
            meta: meta,
            selectedSeason: _selectedSeason,
            onSeasonSelected: (season) =>
                setState(() => _selectedSeason = season),
          );
        },
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  final String message;
  const _ErrorBody({required this.message});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Stack(
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(message, textAlign: TextAlign.center),
            ),
          ),
          const _BackButton(),
        ],
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 8,
      left: 8,
      child: IconButton.filledTonal(
        icon: const Icon(Icons.arrow_back_rounded),
        onPressed: () => Navigator.of(context).maybePop(),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final AddonMeta meta;
  final int? selectedSeason;
  final ValueChanged<int> onSeasonSelected;

  const _Body({
    required this.meta,
    required this.selectedSeason,
    required this.onSeasonSelected,
  });

  MultimediaItem get _item => meta.toMultimediaItem();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final seasons = meta.seasons;
    final activeSeason = selectedSeason ?? (seasons.isEmpty ? 1 : seasons.first);
    final episodes = meta.episodesForSeason(activeSeason);

    return CustomScrollView(
      slivers: [
        SliverAppBar(
          expandedHeight: 260,
          pinned: true,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          flexibleSpace: FlexibleSpaceBar(
            background: Stack(
              fit: StackFit.expand,
              children: [
                if (meta.background != null)
                  CachedNetworkImage(
                    imageUrl: meta.background!,
                    fit: BoxFit.cover,
                    errorWidget: (_, _, _) =>
                        ColoredBox(color: cs.surfaceContainerHighest),
                  )
                else
                  ColoredBox(color: cs.surfaceContainerHighest),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        cs.surface.withValues(alpha: 0.95),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  meta.name,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (meta.releaseInfo != null)
                      Text(
                        meta.releaseInfo!,
                        style: theme.textTheme.bodySmall,
                      ),
                    if (meta.imdbRating != null)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.star_rounded,
                            size: 15,
                            color: Colors.amber,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            meta.imdbRating!,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    if (meta.runtime != null)
                      Text(meta.runtime!, style: theme.textTheme.bodySmall),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: cs.tertiary.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        meta.addonName.isEmpty ? 'ADD-ON' : meta.addonName,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: cs.tertiary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (meta.videos.isEmpty)
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => AddonSourcesSheet.open(
                            context,
                            item: _item,
                            type: meta.type,
                            contentId: meta.id,
                          ),
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: const Text('Play'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => AddonSourcesSheet.open(
                            context,
                            item: _item,
                            type: meta.type,
                            contentId: meta.id,
                            mode: SourcesMode.download,
                          ),
                          icon: const Icon(Icons.download_rounded),
                          label: const Text('Download'),
                        ),
                      ),
                    ],
                  ),
                if (meta.description != null) ...[
                  const SizedBox(height: 16),
                  Text(meta.description!, style: theme.textTheme.bodyMedium),
                ],
                if (meta.genres.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final genre in meta.genres)
                        Chip(
                          label: Text(genre),
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                ],
                if (seasons.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  SizedBox(
                    height: 40,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: seasons.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final season = seasons[index];
                        return ChoiceChip(
                          label: Text('Season $season'),
                          selected: season == activeSeason,
                          onSelected: (_) => onSeasonSelected(season),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (episodes.isNotEmpty)
          SliverList.builder(
            itemCount: episodes.length,
            itemBuilder: (context, index) {
              final video = episodes[index];
              final episode = video.toEpisode();
              return ListTile(
                leading: video.thumbnail == null
                    ? const Icon(Icons.play_circle_outline_rounded)
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: CachedNetworkImage(
                          imageUrl: video.thumbnail!,
                          width: 70,
                          height: 42,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) =>
                              const Icon(Icons.image_not_supported_outlined),
                        ),
                      ),
                title: Text(
                  'E${video.episode ?? index + 1} · ${video.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: video.released == null
                    ? null
                    : Text(
                        video.released!.split('T').first,
                        style: theme.textTheme.labelSmall,
                      ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Play',
                      icon: const Icon(Icons.play_arrow_rounded),
                      onPressed: () => AddonSourcesSheet.open(
                        context,
                        item: _item,
                        type: meta.type,
                        contentId: meta.id,
                        videoId: video.id,
                        episode: episode,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Download',
                      icon: const Icon(Icons.download_rounded),
                      onPressed: () => AddonSourcesSheet.open(
                        context,
                        item: _item,
                        type: meta.type,
                        contentId: meta.id,
                        videoId: video.id,
                        episode: episode,
                        mode: SourcesMode.download,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 90)),
      ],
    );
  }
}
