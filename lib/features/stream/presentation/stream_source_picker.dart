import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/router/app_router.dart';
import '../data/stream_aggregator.dart';
import '../data/stream_browser_provider.dart' show streamAggregatorProvider;
import '../data/stream_source.dart';

class StreamSourcePicker extends ConsumerStatefulWidget {
  final MultimediaItem target;
  final Episode? episode;
  const StreamSourcePicker({super.key, required this.target, this.episode});

  static Future<void> open(
    BuildContext context,
    WidgetRef ref,
    MultimediaItem target, {
    Episode? episode,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => StreamSourcePicker(target: target, episode: episode),
    );
  }

  @override
  ConsumerState<StreamSourcePicker> createState() => _StreamSourcePickerState();
}

class _StreamSourcePickerState extends ConsumerState<StreamSourcePicker> {
  StreamSubscription<StreamAggregateResult>? _sub;
  StreamAggregateResult _result = const StreamAggregateResult(isLoading: true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _start() {
    final manager = ref.read(extensionManagerProvider.notifier);
    final aggregator = ref.read(streamAggregatorProvider);
    final stream = widget.episode == null
        ? aggregator.aggregateForMovie(manager: manager, target: widget.target)
        : aggregator.aggregateForEpisode(
            manager: manager,
            target: widget.target,
            episode: widget.episode!,
          );
    _sub = stream.listen((result) {
      if (mounted) setState(() => _result = result);
    });
  }

  void _play(AggregatedStream source) {
    Navigator.pop(context);
    PlayerRoute(
      $extra: PlayerRouteExtra(
        item: source.detailedItem,
        videoUrl: source.episodeUrl,
        episode: source.episode,
        preloadedStreams: _result.streams
            .map(
              (e) => e.stream.copyWith(
                providerName: e.providerName,
                source: e.stream.source,
              ),
            )
            .toList(),
      ),
    ).push<void>(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = widget.episode == null
        ? widget.target.title
        : '${widget.target.title} • S${widget.episode!.season} E${widget.episode!.episode}';

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.45,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10),
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: theme.dividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  if (widget.target.posterUrl.isNotEmpty)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: CachedNetworkImage(
                        imageUrl: widget.target.posterUrl,
                        width: 44,
                        height: 64,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => const SizedBox(
                          width: 44,
                          height: 64,
                          child: Icon(Icons.movie_outlined),
                        ),
                      ),
                    ),
                  if (widget.target.posterUrl.isNotEmpty)
                    const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Stream sources',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (_result.isLoading)
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    _result.streams.isEmpty
                        ? Icons.cloud_off_outlined
                        : Icons.cloud_done_outlined,
                    size: 16,
                    color: _result.streams.isEmpty
                        ? theme.colorScheme.error
                        : Colors.green,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _result.isLoading
                          ? 'Checked ${_result.searchedProviders.length} plugins, found ${_result.streams.length} links...'
                          : '${_result.streams.length} links from ${_result.readyProviders.length} plugins',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _result.streams.isEmpty && !_result.isLoading
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _result.error ??
                              'No links found for this title in installed plugins.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView.separated(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                      itemCount: _result.streams.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final source = _result.streams[index];
                        return Card(
                          elevation: 0,
                          child: ListTile(
                            onTap: () => _play(source),
                            leading: const Icon(Icons.play_circle_fill),
                            title: Text(source.providerName),
                            subtitle: Text(
                              source.stream.source,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: const Icon(Icons.chevron_right),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
