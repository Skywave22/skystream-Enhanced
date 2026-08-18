import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/addons/services/link_probe_service.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/download_service.dart';
import '../../stream/data/stream_aggregator.dart';
import '../../stream/data/stream_browser_provider.dart'
    show streamAggregatorProvider;
import '../../stream/data/stream_source.dart';
import 'source_sheet_widgets.dart';

/// Plugin-powered sources sheet used from Explore / TMDB details.
///
/// This is the "Available Sources (BETA)" pipeline: every installed plugin is
/// searched for the exact title, its links are ranked, tested and shown with a
/// real resolution, and each row can be played *or* downloaded.
///
/// It deliberately knows nothing about Stremio add-ons — add-ons live in their
/// own tab with their own sheet and their own player.
class PluginSourcesSheet extends ConsumerStatefulWidget {
  final MultimediaItem target;
  final Episode? episode;
  final SourcesMode mode;

  const PluginSourcesSheet({
    super.key,
    required this.target,
    this.episode,
    this.mode = SourcesMode.play,
  });

  static Future<void> open(
    BuildContext context,
    MultimediaItem target, {
    Episode? episode,
    SourcesMode mode = SourcesMode.play,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          PluginSourcesSheet(target: target, episode: episode, mode: mode),
    );
  }

  @override
  ConsumerState<PluginSourcesSheet> createState() => _PluginSourcesSheetState();
}

class _PluginSourcesSheetState extends ConsumerState<PluginSourcesSheet> {
  StreamSubscription<StreamAggregateResult>? _sub;
  StreamAggregateResult _result = const StreamAggregateResult(isLoading: true);

  final Map<String, LinkProbeResult> _probes = {};
  final Set<String> _probing = {};

  late SourcesMode _mode;
  final Set<String> _pluginFilter = {};
  bool _hdOnly = false;
  bool _verifiedOnly = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.mode;
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _disposed = true;
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
      if (_disposed) return;
      setState(() => _result = result);
      _scheduleProbes();
    });
  }

  /// Tests the most promising links in the background so rows can show a
  /// working/dead badge plus the real size and HLS resolution.
  void _scheduleProbes() {
    final service = ref.read(linkProbeServiceProvider);
    for (final source in _result.streams.take(16)) {
      final url = source.stream.url;
      if (!url.startsWith('http')) continue;
      if (_probes.containsKey(url) || _probing.contains(url)) continue;
      _probing.add(url);
      unawaited(
        service.probe(url, headers: source.stream.headers).then((result) {
          if (_disposed) return;
          setState(() {
            _probes[url] = result;
            _probing.remove(url);
          });
        }),
      );
    }
  }

  List<AggregatedStream> get _visible {
    return _result.streams.where((s) {
      if (_pluginFilter.isNotEmpty && !_pluginFilter.contains(s.providerName)) {
        return false;
      }
      if (_hdOnly && s.qualityScore < 1080) return false;
      if (_mode == SourcesMode.download && !s.stream.url.startsWith('http')) {
        return false;
      }
      if (_verifiedOnly) {
        final probe = _probes[s.stream.url];
        if (probe == null || !probe.reachable) return false;
      }
      return true;
    }).toList();
  }

  void _play(AggregatedStream source) {
    Navigator.of(context).pop();
    unawaited(
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
      ).push<void>(context),
    );
  }

  Future<void> _download(AggregatedStream source) async {
    final messenger = ScaffoldMessenger.of(context);
    final url = source.stream.url;
    if (!url.startsWith('http')) {
      messenger.showSnackBar(
        const SnackBar(content: Text('This link can only be streamed.')),
      );
      return;
    }

    final service = ref.read(downloadServiceProvider);
    final item = source.detailedItem;
    final episode = source.episode;

    try {
      final saveDir = await service.getDownloadPath(item, episode: episode);
      final extension = extensionForUrl(url);

      String filename;
      if (episode != null && item.contentType != MultimediaContentType.movie) {
        final safe = episode.name.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
        filename = 'S${episode.season}-E${episode.episode} $safe$extension';
      } else {
        final safe = item.title.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
        filename = '$safe$extension';
      }

      final started = await service.startDownload(
        url: url,
        filename: filename,
        directory: saveDir,
        item: item,
        episode: episode,
        trackingUrl: source.episodeUrl,
        headers: source.stream.headers,
      );

      if (!mounted) return;
      final resolution =
          _probes[url]?.resolutionLabel ?? source.qualityLabel;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            started
                ? 'Download started · ${source.providerName} · $resolution'
                : 'Failed to start download. Check storage permissions.',
          ),
        ),
      );
      if (started && mounted) Navigator.of(context).maybePop();
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Download failed: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final episode = widget.episode;
    final subtitle = episode == null
        ? widget.target.title
        : '${widget.target.title} • S${episode.season} E${episode.episode}';

    final visible = _visible;
    final plugins = _result.streams.map((e) => e.providerName).toSet().toList()
      ..sort();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.82,
      minChildSize: 0.45,
      maxChildSize: 0.96,
      builder: (context, scrollController) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
          ),
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.only(top: 10),
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              SourceSheetHeader(
                title: 'Available Sources',
                subtitle: subtitle,
                trailing: const SourceTag(text: 'PLUGINS', color: Colors.teal),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: SegmentedButton<SourcesMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: SourcesMode.play,
                      icon: Icon(Icons.play_arrow_rounded, size: 18),
                      label: Text('Play'),
                    ),
                    ButtonSegment(
                      value: SourcesMode.download,
                      icon: Icon(Icons.download_rounded, size: 18),
                      label: Text('Download'),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (value) =>
                      setState(() => _mode = value.first),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _result.isLoading
                            ? 'Searching plugins… ${_result.completedCount}/${_result.totalCount}'
                            : '${_result.streams.length} links from ${_result.readyProviders.length} plugins',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _result.isLoading
                              ? cs.primary
                              : cs.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (_result.isLoading)
                      SizedBox(
                        width: 90,
                        child: LinearProgressIndicator(
                          value: _result.progress == 0
                              ? null
                              : _result.progress,
                          minHeight: 4,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(
                height: 42,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: const Text('1080p+'),
                        selected: _hdOnly,
                        onSelected: (value) => setState(() => _hdOnly = value),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        avatar: const Icon(Icons.verified_rounded, size: 16),
                        label: const Text('Tested'),
                        selected: _verifiedOnly,
                        onSelected: (value) =>
                            setState(() => _verifiedOnly = value),
                      ),
                    ),
                    for (final plugin in plugins)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FilterChip(
                          label: Text(plugin),
                          selected: _pluginFilter.contains(plugin),
                          onSelected: (value) => setState(() {
                            if (value) {
                              _pluginFilter.add(plugin);
                            } else {
                              _pluginFilter.remove(plugin);
                            }
                          }),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: visible.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: _result.isLoading
                              ? const Text('Searching installed plugins…')
                              : Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.cloud_off_outlined,
                                      size: 40,
                                      color: cs.onSurfaceVariant,
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      _result.streams.isNotEmpty
                                          ? 'No links match the current filters.'
                                          : (_result.error ??
                                                'No links found for this title in installed plugins.'),
                                      textAlign: TextAlign.center,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: cs.onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                        ),
                      )
                    : ListView.separated(
                        controller: scrollController,
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                        itemCount: visible.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final source = visible[index];
                          final url = source.stream.url;
                          return _PluginSourceRow(
                            source: source,
                            probe: _probes[url],
                            probing: _probing.contains(url),
                            isBest: index == 0,
                            downloadMode: _mode == SourcesMode.download,
                            onPlay: () => _play(source),
                            onDownload: () => unawaited(_download(source)),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PluginSourceRow extends StatelessWidget {
  final AggregatedStream source;
  final LinkProbeResult? probe;
  final bool probing;
  final bool isBest;
  final bool downloadMode;
  final VoidCallback onPlay;
  final VoidCallback onDownload;

  const _PluginSourceRow({
    required this.source,
    required this.probe,
    required this.probing,
    required this.isBest,
    required this.downloadMode,
    required this.onPlay,
    required this.onDownload,
  });

  Color _avatarColor() {
    const palette = [
      Color(0xFF7C6BF5),
      Color(0xFF4CAF50),
      Color(0xFFFF9800),
      Color(0xFF2196F3),
      Color(0xFF26C6DA),
      Color(0xFFEC407A),
      Color(0xFFFFC107),
    ];
    return palette[source.providerName.hashCode.abs() % palette.length];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final letter = source.providerName.isEmpty
        ? '?'
        : source.providerName.substring(0, 1).toUpperCase();
    final resolution = probe?.resolutionLabel ?? source.qualityLabel;
    final size = probe?.sizeLabel;
    final canDownload = source.stream.url.startsWith('http');

    return Material(
      color: cs.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: downloadMode && canDownload ? onDownload : onPlay,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: isBest
                ? Border.all(
                    color: cs.primary.withValues(alpha: 0.8),
                    width: 1.5,
                  )
                : null,
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 21,
                backgroundColor: _avatarColor(),
                child: Text(
                  letter,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 17,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          resolution,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (source.isHdr)
                          SourceTag(text: 'HDR', color: cs.tertiary),
                        if (source.isAdaptive)
                          SourceTag(text: 'HLS', color: cs.secondary),
                        if (isBest) SourceTag(text: 'BEST', color: cs.primary),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      source.sourceLabel,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (size != null) ...[
                          Text(
                            size,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        ProbeBadge(probe: probe, probing: probing),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Play',
                onPressed: onPlay,
                icon: const Icon(Icons.play_arrow_rounded),
              ),
              IconButton(
                tooltip: canDownload ? 'Download' : 'Stream-only link',
                onPressed: canDownload ? onDownload : null,
                icon: const Icon(Icons.download_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
