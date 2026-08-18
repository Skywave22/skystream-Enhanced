import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/addons/addon_manager.dart';
import '../../../core/addons/models/addon_meta.dart';
import '../../../core/addons/models/addon_stream.dart';
import '../../../core/addons/services/addon_stream_aggregator.dart';
import '../../../core/addons/services/imdb_resolver.dart';
import '../../../core/addons/services/link_probe_service.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/download_service.dart';
import '../../stream/data/stream_aggregator.dart';
import '../../stream/data/stream_browser_provider.dart' show streamAggregatorProvider;
import '../../stream/data/stream_source.dart';

/// Where a link came from.
enum SourceOrigin { plugin, addon }

/// What the user opened the sheet for. Both actions stay available on every
/// row — the mode only decides the default emphasis and the initial filter.
enum SourcesMode { play, download }

/// A single row in the sheet: either a plugin-resolved link or an add-on one.
class UnifiedSource {
  final SourceOrigin origin;
  final AggregatedStream? plugin;
  final AddonStream? addon;

  const UnifiedSource.fromPlugin(AggregatedStream this.plugin)
    : origin = SourceOrigin.plugin,
      addon = null;

  const UnifiedSource.fromAddon(AddonStream this.addon)
    : origin = SourceOrigin.addon,
      plugin = null;

  bool get isAddon => origin == SourceOrigin.addon;

  String get providerName =>
      isAddon ? addon!.addonName : plugin!.providerName;

  String get subtitleLine =>
      isAddon ? addon!.displayTitle : plugin!.stream.displaySource;

  int get qualityScore => isAddon ? addon!.qualityScore : plugin!.qualityScore;

  String get qualityLabel => isAddon ? addon!.qualityLabel : plugin!.qualityLabel;

  bool get isHdr => isAddon ? addon!.isHdr : plugin!.isHdr;

  bool get isTorrent => isAddon && addon!.isTorrent;

  int? get seeders => isAddon ? addon!.seeders : null;

  String? get sizeLabel => isAddon ? addon!.sizeLabel : null;

  bool get isCachedDebrid => isAddon && addon!.isCachedDebrid;

  /// The URL that can be probed/downloaded. Torrent rows have none.
  String? get httpUrl {
    if (isAddon) {
      final url = addon!.url;
      if (url == null || !url.startsWith('http')) return null;
      return url;
    }
    final url = plugin!.stream.url;
    return url.startsWith('http') ? url : null;
  }

  Map<String, String>? get headers =>
      isAddon ? addon!.proxyHeaders : plugin!.stream.headers;

  bool get canDownload => httpUrl != null;

  String get key => isAddon
      ? 'addon:${addon!.uniqueKey}'
      : 'plugin:${plugin!.providerId}:${plugin!.stream.url}';
}

/// Bottom sheet that merges **installed plugins** and **Stremio add-ons** into
/// one ranked list of links, each playable *and* downloadable, with live
/// link-testing that shows real size/resolution before you commit.
class UnifiedSourcesSheet extends ConsumerStatefulWidget {
  final MultimediaItem target;
  final Episode? episode;
  final String? imdbId;
  final SourcesMode mode;

  const UnifiedSourcesSheet({
    super.key,
    required this.target,
    this.episode,
    this.imdbId,
    this.mode = SourcesMode.play,
  });

  static Future<void> open(
    BuildContext context,
    MultimediaItem target, {
    Episode? episode,
    String? imdbId,
    SourcesMode mode = SourcesMode.play,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => UnifiedSourcesSheet(
        target: target,
        episode: episode,
        imdbId: imdbId,
        mode: mode,
      ),
    );
  }

  @override
  ConsumerState<UnifiedSourcesSheet> createState() =>
      _UnifiedSourcesSheetState();
}

class _UnifiedSourcesSheetState extends ConsumerState<UnifiedSourcesSheet> {
  StreamSubscription<StreamAggregateResult>? _pluginSub;
  StreamSubscription<AddonAggregateState>? _addonSub;

  StreamAggregateResult _pluginResult = const StreamAggregateResult(
    isLoading: true,
  );
  AddonAggregateState _addonResult = const AddonAggregateState(isLoading: true);

  final Map<String, LinkProbeResult> _probes = {};
  final Set<String> _probing = {};

  late SourcesMode _mode;
  _OriginFilter _originFilter = _OriginFilter.all;
  bool _hdOnly = false;
  bool _verifiedOnly = false;
  String? _addonNotice;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.mode;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startPlugins();
      unawaited(_startAddons());
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _pluginSub?.cancel();
    _addonSub?.cancel();
    super.dispose();
  }

  bool get _isSeries =>
      widget.episode != null ||
      widget.target.contentType == MultimediaContentType.series ||
      widget.target.contentType == MultimediaContentType.anime;

  void _startPlugins() {
    final manager = ref.read(extensionManagerProvider.notifier);
    final aggregator = ref.read(streamAggregatorProvider);
    final stream = widget.episode == null
        ? aggregator.aggregateForMovie(manager: manager, target: widget.target)
        : aggregator.aggregateForEpisode(
            manager: manager,
            target: widget.target,
            episode: widget.episode!,
          );
    _pluginSub = stream.listen((result) {
      if (_disposed) return;
      setState(() => _pluginResult = result);
      _scheduleProbes();
    });
  }

  Future<void> _startAddons() async {
    // The manager loads from disk asynchronously; opening the sheet on a cold
    // start must not be mistaken for "no add-ons installed".
    if (ref.read(addonManagerProvider).isLoading) {
      await ref.read(addonManagerProvider.notifier).load();
    }
    if (_disposed) return;

    final addons = ref.read(addonManagerProvider).enabled;
    if (addons.isEmpty) {
      if (_disposed) return;
      setState(() {
        _addonResult = const AddonAggregateState(isLoading: false);
        _addonNotice =
            'No Stremio add-ons installed yet — add one from the Add-ons tab '
            'to unlock more sources.';
      });
      return;
    }

    final imdbId = await ref
        .read(imdbResolverProvider)
        .resolve(
          title: widget.target.title,
          isSeries: _isSeries,
          year: widget.target.year,
          knownImdbId: widget.imdbId ?? widget.target.imdbId,
        );

    if (_disposed) return;
    if (imdbId == null) {
      setState(() {
        _addonResult = const AddonAggregateState(isLoading: false);
        _addonNotice = 'Could not match this title to an IMDb id for add-ons.';
      });
      return;
    }

    final type = _isSeries ? 'series' : 'movie';
    final episode = widget.episode;
    final id = episode == null
        ? imdbId
        : StremioId.forEpisode(imdbId, episode.season, episode.episode);

    final aggregator = ref.read(addonStreamAggregatorProvider);
    _addonSub = aggregator
        .aggregate(addons: addons, type: type, id: id)
        .listen((result) {
          if (_disposed) return;
          setState(() => _addonResult = result);
          _scheduleProbes();
        });
  }

  /// Tests the most promising links in the background so rows can show a
  /// "working / dead" badge plus the real file size and HLS resolution.
  void _scheduleProbes() {
    final candidates = _allSources
        .where((s) => s.httpUrl != null)
        .take(18)
        .toList();
    final service = ref.read(linkProbeServiceProvider);

    for (final source in candidates) {
      final url = source.httpUrl!;
      if (_probes.containsKey(url) || _probing.contains(url)) continue;
      _probing.add(url);
      unawaited(
        service.probe(url, headers: source.headers).then((result) {
          if (_disposed) return;
          setState(() {
            _probes[url] = result;
            _probing.remove(url);
          });
        }),
      );
    }
  }

  List<UnifiedSource> get _allSources {
    final out = <UnifiedSource>[
      for (final s in _pluginResult.streams) UnifiedSource.fromPlugin(s),
      for (final s in _addonResult.streams) UnifiedSource.fromAddon(s),
    ];
    out.sort((a, b) {
      final byQuality = b.qualityScore.compareTo(a.qualityScore);
      if (byQuality != 0) return byQuality;
      if (a.isCachedDebrid != b.isCachedDebrid) {
        return a.isCachedDebrid ? -1 : 1;
      }
      if (a.isHdr != b.isHdr) return a.isHdr ? -1 : 1;
      final seedA = a.seeders ?? -1;
      final seedB = b.seeders ?? -1;
      if (seedA != seedB) return seedB.compareTo(seedA);
      return a.providerName.compareTo(b.providerName);
    });
    return out;
  }

  List<UnifiedSource> get _visibleSources {
    return _allSources.where((s) {
      if (_originFilter == _OriginFilter.plugins && s.isAddon) return false;
      if (_originFilter == _OriginFilter.addons && !s.isAddon) return false;
      if (_hdOnly && s.qualityScore < 1080) return false;
      if (_mode == SourcesMode.download && !s.canDownload) return false;
      if (_verifiedOnly) {
        final url = s.httpUrl;
        if (url == null) return false;
        final probe = _probes[url];
        if (probe == null || !probe.reachable) return false;
      }
      return true;
    }).toList();
  }

  bool get _isLoading => _pluginResult.isLoading || _addonResult.isLoading;

  Future<void> _play(UnifiedSource source) async {
    final navigator = Navigator.of(context);
    if (source.isAddon) {
      final addonStreams = _addonResult.streams;
      final index = addonStreams.indexOf(source.addon!);
      navigator.pop();
      unawaited(
        AddonPlayerRoute(
          $extra: AddonPlayerRouteExtra(
            item: widget.target,
            episode: widget.episode,
            streams: addonStreams,
            initialIndex: index < 0 ? 0 : index,
          ),
        ).push<void>(context),
      );
      return;
    }

    final plugin = source.plugin!;
    navigator.pop();
    unawaited(
      PlayerRoute(
        $extra: PlayerRouteExtra(
          item: plugin.detailedItem,
          videoUrl: plugin.episodeUrl,
          episode: plugin.episode,
          preloadedStreams: _pluginResult.streams
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

  Future<void> _download(UnifiedSource source) async {
    final messenger = ScaffoldMessenger.of(context);
    final url = source.httpUrl;
    if (url == null) {
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
    final item = source.isAddon
        ? widget.target
        : source.plugin!.detailedItem;
    final episode = source.isAddon ? widget.episode : source.plugin!.episode;

    try {
      final saveDir = await service.getDownloadPath(item, episode: episode);
      final extension = _extensionFor(url);

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
        trackingUrl: source.isAddon ? url : source.plugin!.episodeUrl,
        headers: source.headers,
      );

      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            started
                ? 'Download started · ${source.providerName} · ${_resolutionFor(source)}'
                : 'Failed to start download. Check storage permissions.',
          ),
        ),
      );
      if (started && mounted) Navigator.of(context).maybePop();
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Download failed: $error')));
    }
  }

  String _resolutionFor(UnifiedSource source) {
    final url = source.httpUrl;
    final probe = url == null ? null : _probes[url];
    return probe?.resolutionLabel ?? source.qualityLabel;
  }

  static String _extensionFor(String url) {
    final clean = url.split('?').first.toLowerCase();
    for (final ext in const ['.mp4', '.mkv', '.webm', '.avi', '.mov']) {
      if (clean.endsWith(ext)) return ext;
    }
    return '.mp4';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final episode = widget.episode;
    final subtitle = episode == null
        ? widget.target.title
        : '${widget.target.title} • S${episode.season} E${episode.episode}';

    final visible = _visibleSources;
    final pluginCount = _pluginResult.streams.length;
    final addonCount = _addonResult.streams.length;

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
              _header(theme, cs, subtitle),
              _modeSelector(cs),
              _statusLine(theme, cs, pluginCount, addonCount),
              _filters(cs, visible),
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
                          final source = visible[index];
                          final url = source.httpUrl;
                          return _SourceRow(
                            source: source,
                            probe: url == null ? null : _probes[url],
                            probing: url != null && _probing.contains(url),
                            isBest: index == 0,
                            downloadMode: _mode == SourcesMode.download,
                            onPlay: () => unawaited(_play(source)),
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

  Widget _header(ThemeData theme, ColorScheme cs, String subtitle) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
      child: Row(
        children: [
          if (widget.target.posterUrl.isNotEmpty) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: CachedNetworkImage(
                imageUrl: widget.target.posterUrl,
                width: 46,
                height: 68,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => const SizedBox(
                  width: 46,
                  height: 68,
                  child: Icon(Icons.movie_outlined),
                ),
              ),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Available Sources',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeSelector(ColorScheme cs) {
    return Padding(
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
        onSelectionChanged: (value) => setState(() => _mode = value.first),
      ),
    );
  }

  Widget _statusLine(
    ThemeData theme,
    ColorScheme cs,
    int pluginCount,
    int addonCount,
  ) {
    final total = pluginCount + addonCount;
    final completed =
        _pluginResult.completedCount + _addonResult.completedCount;
    final expected = _pluginResult.totalCount + _addonResult.totalCount;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _isLoading
                      ? 'Searching plugins & add-ons… $completed/$expected'
                      : '$total links · $pluginCount from plugins · $addonCount from add-ons',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _isLoading ? cs.primary : cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_isLoading)
                SizedBox(
                  width: 90,
                  child: LinearProgressIndicator(
                    value: expected == 0 ? null : completed / expected,
                    minHeight: 4,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
            ],
          ),
          if (_addonNotice != null) ...[
            const SizedBox(height: 6),
            Text(
              _addonNotice!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _filters(ColorScheme cs, List<UnifiedSource> visible) {
    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final filter in _OriginFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(filter.label),
                selected: _originFilter == filter,
                onSelected: (_) => setState(() => _originFilter = filter),
              ),
            ),
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
              onSelected: (value) => setState(() => _verifiedOnly = value),
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
        child: _isLoading
            ? const Text('Searching installed plugins and add-ons…')
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
                        ? 'No downloadable links found. Torrent sources can be played but not downloaded.'
                        : (_pluginResult.error ??
                              _addonResult.error ??
                              'No links found for this title.'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

enum _OriginFilter {
  all('All'),
  plugins('Plugins'),
  addons('Add-ons');

  const _OriginFilter(this.label);
  final String label;
}

class _SourceRow extends StatelessWidget {
  final UnifiedSource source;
  final LinkProbeResult? probe;
  final bool probing;
  final bool isBest;
  final bool downloadMode;
  final VoidCallback onPlay;
  final VoidCallback onDownload;

  const _SourceRow({
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
    final size = probe?.sizeLabel ?? source.sizeLabel;

    return Material(
      color: cs.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: downloadMode ? onDownload : onPlay,
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
                        _Tag(
                          text: source.isAddon ? 'ADD-ON' : 'PLUGIN',
                          color: source.isAddon ? cs.tertiary : cs.secondary,
                        ),
                        if (source.isHdr) _Tag(text: 'HDR', color: cs.tertiary),
                        if (source.isTorrent)
                          _Tag(text: 'TORRENT', color: cs.primary),
                        if (source.isCachedDebrid)
                          const _Tag(text: 'CACHED', color: Colors.greenAccent),
                        if (isBest) _Tag(text: 'BEST', color: cs.primary),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      source.subtitleLine,
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
                          source.providerName,
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
                        if (source.seeders != null) ...[
                          const SizedBox(width: 8),
                          Icon(
                            Icons.people_alt_outlined,
                            size: 12,
                            color: cs.onSurfaceVariant,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            '${source.seeders}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                        const SizedBox(width: 8),
                        _probeBadge(theme, cs),
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
                tooltip: source.canDownload
                    ? 'Download'
                    : 'Torrent sources cannot be downloaded',
                onPressed: source.canDownload ? onDownload : null,
                icon: const Icon(Icons.download_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _probeBadge(ThemeData theme, ColorScheme cs) {
    if (source.isTorrent) {
      return Text(
        'P2P',
        style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
      );
    }
    if (probing) {
      return SizedBox(
        width: 10,
        height: 10,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: cs.primary),
      );
    }
    final result = probe;
    if (result == null) return const SizedBox.shrink();
    if (result.reachable) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.verified_rounded, size: 12, color: Colors.green),
          const SizedBox(width: 2),
          Text(
            'Working',
            style: theme.textTheme.labelSmall?.copyWith(color: Colors.green),
          ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_outline_rounded, size: 12, color: cs.error),
        const SizedBox(width: 2),
        Text(
          result.failureReason ?? 'Dead link',
          style: theme.textTheme.labelSmall?.copyWith(color: cs.error),
        ),
      ],
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final Color color;
  const _Tag({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: color,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
