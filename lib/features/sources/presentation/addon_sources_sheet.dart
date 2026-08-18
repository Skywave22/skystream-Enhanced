import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/addons/addon_manager.dart';
import '../../../core/addons/models/addon_stream.dart';
import '../../../core/addons/services/addon_stream_aggregator.dart';
import '../../../core/addons/services/imdb_resolver.dart';
import '../../../core/addons/services/link_probe_service.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/download_service.dart';
import 'source_sheet_widgets.dart';

/// Add-on-only sources sheet.
///
/// Everything here comes from installed Stremio add-ons: no plugin is queried,
/// no plugin needs to be installed, and playback goes to the dedicated add-on
/// player. The Explore/plugin pipeline lives in `PluginSourcesSheet`.
class AddonSourcesSheet extends ConsumerStatefulWidget {
  /// Item used for download naming and watch history.
  final MultimediaItem item;

  /// Stremio content type — `movie` or `series`.
  final String type;

  /// The add-on content id (`tt0111161`, `kitsu:1376`, …).
  final String contentId;

  /// Exact video id from the meta object for episodes (`tt0944947:1:5`).
  final String? videoId;

  final Episode? episode;
  final SourcesMode mode;

  const AddonSourcesSheet({
    super.key,
    required this.item,
    required this.type,
    required this.contentId,
    this.videoId,
    this.episode,
    this.mode = SourcesMode.play,
  });

  static Future<void> open(
    BuildContext context, {
    required MultimediaItem item,
    required String type,
    required String contentId,
    String? videoId,
    Episode? episode,
    SourcesMode mode = SourcesMode.play,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddonSourcesSheet(
        item: item,
        type: type,
        contentId: contentId,
        videoId: videoId,
        episode: episode,
        mode: mode,
      ),
    );
  }

  @override
  ConsumerState<AddonSourcesSheet> createState() => _AddonSourcesSheetState();
}

class _AddonSourcesSheetState extends ConsumerState<AddonSourcesSheet> {
  StreamSubscription<AddonAggregateState>? _sub;
  AddonAggregateState _result = const AddonAggregateState(isLoading: true);

  final Map<String, LinkProbeResult> _probes = {};
  final Set<String> _probing = {};

  late SourcesMode _mode;
  bool _hdOnly = false;
  bool _torrentOnly = false;
  bool _disposed = false;
  bool _showDiagnostics = false;
  List<String> _queriedIds = const [];

  @override
  void initState() {
    super.initState();
    _mode = widget.mode;
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }

  /// Builds every id an add-on might recognise for this title/episode.
  ///
  /// Order matters: the meta's own video id is authoritative (it is what the
  /// catalog add-on published), the constructed `base:S:E` covers add-ons that
  /// only understand IMDb episode ids, and the Cinemeta-resolved IMDb id is the
  /// last-resort bridge for non-IMDb catalogs (Kitsu, TMDB-based add-ons).
  Future<List<String>> _candidateIds() async {
    final ids = <String>[];
    final episode = widget.episode;
    final base = widget.contentId.split(':').first;

    if (episode != null) {
      final videoId = widget.videoId;
      if (videoId != null && videoId.isNotEmpty) ids.add(videoId);
      if (episode.url.isNotEmpty && episode.url.contains(':')) {
        ids.add(episode.url);
      }
      if (base.isNotEmpty) {
        ids.add('$base:${episode.season}:${episode.episode}');
      }
    } else {
      if (widget.contentId.isNotEmpty) ids.add(widget.contentId);
    }

    if (!base.startsWith('tt')) {
      final imdbId = await ref
          .read(imdbResolverProvider)
          .resolve(
            title: widget.item.title,
            isSeries: widget.type != 'movie',
            year: widget.item.year,
            knownImdbId: widget.item.imdbId,
          );
      if (imdbId != null) {
        if (episode == null) {
          ids.add(imdbId);
        } else {
          ids.add('$imdbId:${episode.season}:${episode.episode}');
        }
      }
    }
    return ids;
  }

  Future<void> _start({bool forceRefresh = false}) async {
    // The add-on store loads from disk asynchronously; opening the sheet on a
    // cold start must not be mistaken for "no add-ons installed".
    if (ref.read(addonManagerProvider).isLoading) {
      await ref.read(addonManagerProvider.notifier).load();
    }
    if (_disposed) return;

    final addons = ref.read(addonManagerProvider).enabled;
    final ids = await _candidateIds();
    if (_disposed) return;

    setState(() {
      _queriedIds = ids;
      _result = const AddonAggregateState(isLoading: true);
      _probes.clear();
      _probing.clear();
    });

    await _sub?.cancel();
    _sub = ref
        .read(addonStreamAggregatorProvider)
        .aggregate(
          addons: addons,
          type: widget.type,
          ids: ids,
          forceRefresh: forceRefresh,
        )
        .listen((state) {
          if (_disposed) return;
          setState(() => _result = state);
          _scheduleProbes();
        });
  }

  void _scheduleProbes() {
    final service = ref.read(linkProbeServiceProvider);
    for (final stream in _result.streams.take(16)) {
      final url = stream.url;
      if (url == null || !url.startsWith('http')) continue;
      if (_probes.containsKey(url) || _probing.contains(url)) continue;
      _probing.add(url);
      unawaited(
        service.probe(url, headers: stream.proxyHeaders).then((result) {
          if (_disposed) return;
          setState(() {
            _probes[url] = result;
            _probing.remove(url);
          });
        }),
      );
    }
  }

  List<AddonStream> get _visible {
    return _result.streams.where((s) {
      if (_hdOnly && s.qualityScore < 1080) return false;
      if (_torrentOnly && !s.isTorrent) return false;
      if (_mode == SourcesMode.download && !s.isDownloadable) return false;
      return true;
    }).toList();
  }

  void _play(AddonStream stream) {
    final ordered = _visible;
    final index = ordered.indexOf(stream);
    Navigator.of(context).pop();
    unawaited(
      AddonPlayerRoute(
        $extra: AddonPlayerRouteExtra(
          item: widget.item,
          episode: widget.episode,
          streams: ordered,
          initialIndex: index < 0 ? 0 : index,
        ),
      ).push<void>(context),
    );
  }

  Future<void> _download(AddonStream stream) async {
    final messenger = ScaffoldMessenger.of(context);
    final url = stream.url;
    if (url == null || !stream.isDownloadable) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Torrent sources stream directly — press Play to watch instead.',
          ),
        ),
      );
      return;
    }

    final service = ref.read(downloadServiceProvider);
    final item = widget.item;
    final episode = widget.episode;

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
        trackingUrl: url,
        headers: stream.proxyHeaders,
      );

      if (!mounted) return;
      final resolution = _probes[url]?.resolutionLabel ?? stream.qualityLabel;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            started
                ? 'Download started · ${stream.addonName} · $resolution'
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
        ? widget.item.title
        : '${widget.item.title} • S${episode.season} E${episode.episode}';
    final visible = _visible;

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
                title: 'Add-on Sources',
                subtitle: subtitle,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SourceTag(text: 'ADD-ONS', color: cs.tertiary),
                    IconButton(
                      tooltip: 'Refresh (bypass cache)',
                      icon: const Icon(Icons.refresh_rounded),
                      onPressed: () => unawaited(_start(forceRefresh: true)),
                    ),
                  ],
                ),
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
              _statusLine(theme, cs),
              if (_showDiagnostics) _diagnostics(theme, cs),
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
                        label: const Text('Torrent'),
                        selected: _torrentOnly,
                        onSelected: (value) =>
                            setState(() => _torrentOnly = value),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: visible.isEmpty
                    ? _emptyState(theme, cs)
                    : ListView.separated(
                        controller: scrollController,
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                        itemCount: visible.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final stream = visible[index];
                          final url = stream.url;
                          return _AddonSourceRow(
                            stream: stream,
                            probe: url == null ? null : _probes[url],
                            probing: url != null && _probing.contains(url),
                            isBest: index == 0,
                            downloadMode: _mode == SourcesMode.download,
                            onPlay: () => _play(stream),
                            onDownload: () => unawaited(_download(stream)),
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

  Widget _statusLine(ThemeData theme, ColorScheme cs) {
    final loading = _result.isLoading;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              loading
                  ? 'Asking add-ons… ${_result.completedCount}/${_result.totalCount}'
                  : '${_result.streams.length} links from '
                        '${_result.respondedAddons.length} add-on(s)',
              style: theme.textTheme.bodySmall?.copyWith(
                color: loading ? cs.primary : cs.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (loading)
            SizedBox(
              width: 80,
              child: LinearProgressIndicator(
                value: _result.progress == 0 ? null : _result.progress,
                minHeight: 4,
                borderRadius: BorderRadius.circular(2),
              ),
            )
          else
            TextButton.icon(
              onPressed: () =>
                  setState(() => _showDiagnostics = !_showDiagnostics),
              icon: Icon(
                _showDiagnostics
                    ? Icons.expand_less_rounded
                    : Icons.info_outline_rounded,
                size: 16,
              ),
              label: const Text('Details'),
            ),
        ],
      ),
    );
  }

  Widget _diagnostics(ThemeData theme, ColorScheme cs) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Queried ids: ${_queriedIds.join(', ')}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          for (final status in _result.statuses)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                children: [
                  Icon(
                    switch (status.outcome) {
                      AddonQueryOutcome.links => Icons.check_circle_rounded,
                      AddonQueryOutcome.empty => Icons.remove_circle_outline,
                      AddonQueryOutcome.failed => Icons.error_outline_rounded,
                      AddonQueryOutcome.pending => Icons.hourglass_empty_rounded,
                    },
                    size: 13,
                    color: switch (status.outcome) {
                      AddonQueryOutcome.links => Colors.green,
                      AddonQueryOutcome.failed => cs.error,
                      _ => cs.onSurfaceVariant,
                    },
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      switch (status.outcome) {
                        AddonQueryOutcome.links =>
                          '${status.addonName} · ${status.linkCount} links',
                        AddonQueryOutcome.empty =>
                          '${status.addonName} · no links for this id',
                        AddonQueryOutcome.failed =>
                          '${status.addonName} · ${status.message ?? 'request failed'}',
                        AddonQueryOutcome.pending =>
                          '${status.addonName} · waiting…',
                      },
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _emptyState(ThemeData theme, ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: _result.isLoading
            ? const Text('Asking your add-ons…')
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
                    _mode == SourcesMode.download
                        ? 'No downloadable links. Torrent sources can be played but not downloaded.'
                        : (_result.error ??
                              'No add-on returned links for this title.'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    alignment: WrapAlignment.center,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: () => unawaited(_start(forceRefresh: true)),
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Retry'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () =>
                            setState(() => _showDiagnostics = true),
                        icon: const Icon(Icons.info_outline_rounded),
                        label: const Text('Why?'),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

class _AddonSourceRow extends StatelessWidget {
  final AddonStream stream;
  final LinkProbeResult? probe;
  final bool probing;
  final bool isBest;
  final bool downloadMode;
  final VoidCallback onPlay;
  final VoidCallback onDownload;

  const _AddonSourceRow({
    required this.stream,
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
    return palette[stream.addonName.hashCode.abs() % palette.length];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final letter = stream.addonName.isEmpty
        ? '?'
        : stream.addonName.substring(0, 1).toUpperCase();
    final resolution = probe?.resolutionLabel ?? stream.qualityLabel;
    final size = probe?.sizeLabel ?? stream.sizeLabel;

    return Material(
      color: cs.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: downloadMode && stream.isDownloadable ? onDownload : onPlay,
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
                        if (stream.isHdr)
                          SourceTag(text: 'HDR', color: cs.tertiary),
                        if (stream.isTorrent)
                          SourceTag(text: 'TORRENT', color: cs.primary),
                        if (stream.isCachedDebrid)
                          const SourceTag(
                            text: 'CACHED',
                            color: Colors.greenAccent,
                          ),
                        if (isBest) SourceTag(text: 'BEST', color: cs.primary),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      stream.displayTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          stream.addonName,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        if (size != null) ...[
                          const SizedBox(width: 8),
                          Text(
                            size,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                        if (stream.seeders != null) ...[
                          const SizedBox(width: 8),
                          Icon(
                            Icons.people_alt_outlined,
                            size: 12,
                            color: cs.onSurfaceVariant,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            '${stream.seeders}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                        const SizedBox(width: 8),
                        ProbeBadge(
                          probe: probe,
                          probing: probing,
                          isPeerToPeer: stream.isTorrent,
                        ),
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
                tooltip: stream.isDownloadable
                    ? 'Download'
                    : 'Torrent sources cannot be downloaded',
                onPressed: stream.isDownloadable ? onDownload : null,
                icon: const Icon(Icons.download_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
