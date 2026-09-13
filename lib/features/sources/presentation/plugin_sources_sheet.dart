import 'dart:async';
import 'dart:ui' as ui;

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/network/link_probe_service.dart';
import '../../../core/nuvio/data/nuvio_stream_service.dart';
import '../../../core/nuvio/models/nuvio_models.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/download_service.dart';
import '../../../core/utils/source_text.dart';
import '../../../l10n/generated/app_localizations.dart';
import 'source_sheet_widgets.dart';

/// Why the source list came up empty, as far as the sheet can actually tell.
///
/// `NuvioStreamService` already reports a [NuvioScraperStatus] per scraper, so
/// "a scraper threw", "every scraper answered and none had it" and "there are
/// no scrapers" are three separate facts the sheet holds and used to throw
/// away: all of them rendered as `No links found. Verify scraper repos are
/// installed.`, which is advice for exactly one of them and sends everybody
/// else off to reinstall plugins that were working.
///
/// Deliberately absent: an `offline` reason. Nothing at this layer can tell a
/// dead network from a dead scraper mirror — both arrive as every scraper
/// failing — so [allScrapersFailed] names the connection first and leaves the
/// per-scraper reasons to the Details panel instead of guessing.
enum SourcesEmptyReason {
  /// Scrapers are still running; nothing has been decided yet.
  searching,

  /// Links exist, the quality/provider/verified filters are hiding them.
  hiddenByFilters,

  /// No TMDB id to search with. Nuvio scrapers take a numeric id and nothing
  /// else, so this never reached a scraper at all.
  noTmdbId,

  /// No enabled scraper supports this media type.
  noScrapers,

  /// Every scraper that ran threw. Offline, or the scrapers are broken.
  allScrapersFailed,

  /// Some scrapers threw and the rest found nothing, so the empty list is not
  /// trustworthy.
  someScrapersFailed,

  /// Every scraper answered and none of them has this title.
  nobodyHasIt,
}

/// Classifies [progress] into the one thing worth telling the user.
///
/// [hasRows] is whether any link was resolved at all (before filtering) and
/// [hasTmdbId] whether the sheet had an id to search with.
SourcesEmptyReason sourcesEmptyReason({
  required NuvioProgress progress,
  required bool hasRows,
  required bool hasTmdbId,
}) {
  if (progress.isLoading) return SourcesEmptyReason.searching;
  if (hasRows) return SourcesEmptyReason.hiddenByFilters;
  if (!hasTmdbId) return SourcesEmptyReason.noTmdbId;
  if (progress.statuses.isEmpty) return SourcesEmptyReason.noScrapers;
  final int failed = progress.statuses
      .where((status) => status.outcome == NuvioScraperOutcome.failed)
      .length;
  if (failed == 0) return SourcesEmptyReason.nobodyHasIt;
  return failed == progress.statuses.length
      ? SourcesEmptyReason.allScrapersFailed
      : SourcesEmptyReason.someScrapersFailed;
}

/// Nuvio-powered sources sheet used from Explore / TMDB details.
///
/// Runs scraper repositories in Nuvio's format on background isolates with
/// `getStreams(tmdbId, mediaType, season, episode)`.
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
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.65),
      builder: (_) =>
          PluginSourcesSheet(target: target, episode: episode, mode: mode),
    );
  }

  @override
  ConsumerState<PluginSourcesSheet> createState() => _PluginSourcesSheetState();
}

/// One row wrapping a resolved Nuvio scraper link.
class _Row {
  final NuvioStreamResult nuvio;

  const _Row(this.nuvio);

  String get url => nuvio.url;

  String get providerName => nuvio.scraperName;

  /// Consistent detail line: size, language, seeders, and stream name.
  String get detail => buildSourceDetail([
    nuvio.size,
    nuvio.language,
    nuvio.seeders == null ? null : '${nuvio.seeders} seeds',
    nuvio.name ?? nuvio.title,
  ], fallback: providerName);

  Map<String, String>? get headers => nuvio.headers;

  bool get isTorrent => nuvio.isTorrent;

  bool get canDownload => url.startsWith('http') && !isTorrent;

  static final RegExp _res = RegExp(
    r'(\d{3,4})\s*[pi]\b',
    caseSensitive: false,
  );
  static final RegExp _uhd = RegExp(r'\b(4k|uhd|2160)\b', caseSensitive: false);
  static final RegExp _qhd = RegExp(r'\b(1440|2k)\b', caseSensitive: false);
  static final RegExp _fhd = RegExp(r'\b(1080|fhd)\b', caseSensitive: false);
  static final RegExp _hd = RegExp(r'\b(720|hd)\b', caseSensitive: false);
  static final RegExp _sd = RegExp(r'\b(480|sd)\b', caseSensitive: false);
  static final RegExp _low = RegExp(r'\b(360)\b', caseSensitive: false);

  /// Scrapers label quality inconsistently, so bare tokens like `fhd` or
  /// `1080` are honoured — but only in the metadata a scraper authored. A URL
  /// is full of unrelated numbers (`?exp=360`, `?id=1080&t=1`) that would
  /// otherwise score a junk link as the best source in the list, so it is
  /// only searched for the unambiguous `1080p` / `1080i` form.
  int get qualityScore {
    final meta = '${nuvio.quality ?? ''} ${nuvio.title}';
    if (_uhd.hasMatch(meta)) return 2160;
    if (_qhd.hasMatch(meta)) return 1440;
    final match = _res.firstMatch('$meta ${nuvio.url}');
    if (match != null) return int.tryParse(match.group(1)!) ?? 0;
    if (_fhd.hasMatch(meta)) return 1080;
    if (_hd.hasMatch(meta)) return 720;
    if (_sd.hasMatch(meta)) return 480;
    if (_low.hasMatch(meta)) return 360;
    return 0;
  }

  String get qualityLabel {
    final score = qualityScore;
    if (score >= 2160) return '4K';
    if (score >= 1440) return '2K';
    if (score > 0) return '${score}p';
    final quality = nuvio.quality?.trim();
    if (quality == null || quality.isEmpty) return 'Auto';
    final clean = quality.split(RegExp(r'[|/,]')).first.trim();
    if (clean.length > 8) {
      return 'Auto';
    }
    return clean.isEmpty ? 'Auto' : clean;
  }

  bool get isHdr => RegExp(
    r'\b(hdr10\+?|hdr|dolby\s*vision|dovi)\b',
    caseSensitive: false,
  ).hasMatch('${nuvio.quality ?? ''} ${nuvio.title}');

  String get key => 'nuvio:${nuvio.scraperId}:${nuvio.url}';

  StreamResult toStreamResult() => nuvio.toStreamResult();
}


/// Section chrome in the flattened list.
enum _SectionKind { topPick, ready, unavailableToggle }

/// One entry of the flattened list the sheet renders.
///
/// [ListView.builder] needs an index-addressable model, and the sections
/// (Top pick / Ready / Unavailable) are otherwise nested. Describing each
/// entry instead of building it keeps a row's three [FocusNode]s off the heap
/// until it scrolls into view, and stops every probe result from rebuilding
/// every row.
sealed class _Entry {
  /// Gap below this entry, reproducing the spacing of the nested layout.
  final double gap;

  const _Entry({required this.gap});
}

class _SectionEntry extends _Entry {
  final _SectionKind kind;
  final int count;

  const _SectionEntry(this.kind, {required this.count, required super.gap});
}

class _RowEntry extends _Entry {
  final _Row row;
  final bool isBest;
  final bool autofocus;

  /// Unavailable rows are shown faded, as in the collapsed section.
  final bool faded;

  const _RowEntry(
    this.row, {
    required this.isBest,
    required this.autofocus,
    required this.faded,
    required super.gap,
  });
}

class _PluginSourcesSheetState extends ConsumerState<PluginSourcesSheet> {
  StreamSubscription<NuvioProgress>? _nuvioSub;

  NuvioProgress _nuvioResult = const NuvioProgress(isLoading: true);
  bool _showDiagnostics = false;

  final Map<String, LinkProbeResult> _probes = {};
  final Set<String> _probing = {};

  /// Title / TMDB id the user typed in "Search manually".
  String? _titleOverride;
  String? _tmdbOverride;
  final Set<String> _providerFilter = {};
  bool _hdOnly = false;
  bool _verifiedOnly = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startNuvio();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _nuvioSub?.cancel();
    super.dispose();
  }

  /// The id the scrapers are actually given. Nuvio plugins are written against
  /// a numeric TMDB id; without one the sheet never reaches a scraper, which is
  /// a different empty list from a scraper coming back with nothing.
  String get _searchId =>
      (_tmdbOverride ?? widget.target.tmdbId?.toString() ?? '').trim();

  void _startNuvio() {
    final tmdbId = _searchId;
    if (tmdbId.isEmpty) {
      setState(() => _nuvioResult = const NuvioProgress(isLoading: false));
      return;
    }
    final isSeries =
        widget.episode != null ||
        widget.target.contentType == MultimediaContentType.series ||
        widget.target.contentType == MultimediaContentType.anime;

    _nuvioSub = ref
        .read(nuvioStreamServiceProvider)
        .resolve(
          tmdbId: tmdbId,
          mediaType: isSeries ? 'tv' : 'movie',
          season: widget.episode?.season,
          episode: widget.episode?.episode,
        )
        .listen((progress) {
          if (_disposed) return;
          setState(() => _nuvioResult = progress);
          _scheduleProbes();
        });
  }

  /// Re-runs the search with a title or TMDB id the user types.
  Future<void> _searchManually() async {
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _ManualSearchDialog(
        initialText: _titleOverride ?? widget.target.title,
        hasOverride: _titleOverride != null || _tmdbOverride != null,
      ),
    );
    if (value == null || !mounted) return;

    final tmdbMatch = RegExp(r'^(?:tmdb:)?(\d{2,9})$').firstMatch(value);
    setState(() {
      if (value.isEmpty) {
        _titleOverride = null;
        _tmdbOverride = null;
      } else if (tmdbMatch != null) {
        _tmdbOverride = tmdbMatch.group(1);
        _titleOverride = null;
      } else {
        _titleOverride = value;
        _tmdbOverride = null;
      }
      _nuvioResult = const NuvioProgress(isLoading: true);
      _probes.clear();
      _probing.clear();
      // A new search is a new list; let it place focus again.
      _autofocusClaimed = false;
      _focusedRowKey = null;
    });
    await _nuvioSub?.cancel();
    _startNuvio();
  }

  static const int _maxParallelProbes = 6;

  void _scheduleProbes() {
    final service = ref.read(linkProbeServiceProvider);
    for (final row in _allRows) {
      if (_probing.length >= _maxParallelProbes) return;
      final url = row.url;
      if (!url.startsWith('http')) continue;
      if (_probes.containsKey(url) || _probing.contains(url)) continue;
      _probing.add(url);
      unawaited(
        service.probe(url, headers: row.headers).then((result) {
          if (_disposed) return;
          setState(() {
            _probes[url] = result;
            _probing.remove(url);
          });
          _scheduleProbes();
        }),
      );
    }
  }

  List<_Row> get _allRows {
    final rows = <_Row>[
      for (final stream in _nuvioResult.streams) _Row(stream),
    ];
    rows.sort((a, b) {
      final byQuality = b.qualityScore.compareTo(a.qualityScore);
      if (byQuality != 0) return byQuality;
      if (a.isHdr != b.isHdr) return a.isHdr ? -1 : 1;
      return a.providerName.compareTo(b.providerName);
    });
    return rows;
  }

  List<_Row> get _visible => _allRows.where((row) {
    if (_providerFilter.isNotEmpty &&
        !_providerFilter.contains(row.providerName)) {
      return false;
    }
    if (_hdOnly && row.qualityScore < 1080) return false;
    // Opened to download: a stream-only link is not a candidate. Matches the
    // addon sheet, and restores the filter PR #98 dropped along with the
    // Play/Download toggle.
    if (_downloadMode && !row.canDownload) return false;
    if (_verifiedOnly) {
      final probe = _probes[row.url];
      if (probe == null || !probe.reachable) return false;
    }
    return true;
  }).toList();

  bool get _isLoading => _nuvioResult.isLoading;

  /// What to put where the list would be. See [SourcesEmptyReason] for why
  /// this is seven sentences and not one.
  String _emptyMessage(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context)!;
    final List<NuvioScraperStatus> statuses = _nuvioResult.statuses;
    return switch (sourcesEmptyReason(
      progress: _nuvioResult,
      hasRows: _allRows.isNotEmpty,
      hasTmdbId: _searchId.isNotEmpty,
    )) {
      SourcesEmptyReason.searching => l10n.sourcesSearching,
      SourcesEmptyReason.hiddenByFilters => l10n.sourcesEmptyFiltered,
      SourcesEmptyReason.noTmdbId => l10n.sourcesEmptyNoTmdbId,
      SourcesEmptyReason.noScrapers => l10n.sourcesEmptyNoScrapers,
      SourcesEmptyReason.allScrapersFailed => l10n.sourcesEmptyAllFailed,
      SourcesEmptyReason.someScrapersFailed => l10n.sourcesEmptySomeFailed(
        statuses
            .where((s) => s.outcome == NuvioScraperOutcome.failed)
            .length,
        statuses.length,
      ),
      SourcesEmptyReason.nobodyHasIt => l10n.sourcesEmptyNothingFound,
    };
  }

  void _play(_Row row) {
    final ordered = <_Row>[row, ..._visible.where((r) => r.key != row.key)];
    final streams = [for (final r in ordered) r.toStreamResult()];

    final item = widget.target;
    final episode = widget.episode;
    final videoUrl = widget.target.url.isNotEmpty
        ? widget.target.url
        : 'tmdb:${widget.target.tmdbId}';

    Navigator.of(context).pop();
    unawaited(
      PlayerRoute(
        $extra: PlayerRouteExtra(
          item: item,
          videoUrl: videoUrl,
          episode: episode,
          preloadedStreams: streams,
        ),
      ).push<void>(context),
    );
  }

  Future<void> _download(_Row row) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!row.canDownload) {
      messenger.showSnackBar(
        const SnackBar(content: Text('This link can only be streamed.')),
      );
      return;
    }

    final service = ref.read(downloadServiceProvider);
    final item = widget.target;
    final episode = widget.episode;

    try {
      final saveDir = await service.getDownloadPath(item, episode: episode);
      final extension = extensionForUrl(row.url);

      String filename;
      if (episode != null && item.contentType != MultimediaContentType.movie) {
        final safe = episode.name.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
        filename = 'S${episode.season}-E${episode.episode} $safe$extension';
      } else {
        final safe = item.title.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
        filename = '$safe$extension';
      }

      final started = await service.startDownload(
        url: row.url,
        filename: filename,
        directory: saveDir,
        item: item,
        episode: episode,
        trackingUrl: row.url,
        headers: row.headers,
      );

      if (!mounted) return;
      final resolution = _probes[row.url]?.resolutionLabel ?? row.qualityLabel;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            started
                ? 'Download started · ${row.providerName} · $resolution'
                : 'Failed to start download. Check storage permissions.',
          ),
        ),
      );
      if (started && mounted) unawaited(Navigator.of(context).maybePop());
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Download failed: $error')),
      );
    }
  }

  Widget _diagnosticsPanel(ThemeData theme, ColorScheme cs) {
    final palette = GlassPalette.of(context);
    final statuses = _nuvioResult.statuses.toList()
      ..sort((a, b) => a.scraperName.compareTo(b.scraperName));
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.tint(0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.tint(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Nuvio scrapers · ${statuses.length}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: palette.ink,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _diagnosticsReport()));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Diagnostics copied')),
                  );
                },
                icon: const Icon(Icons.copy_rounded, size: 14),
                label: const Text('Copy'),
              ),
            ],
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 120),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final status in statuses)
                    Text(
                      '${status.scraperName}: '
                      '${status.outcome == NuvioScraperOutcome.links ? '${status.linkCount} links' : (status.message ?? status.outcome.name)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: status.outcome == NuvioScraperOutcome.failed
                            ? cs.error
                            : cs.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _diagnosticsReport() {
    final buffer = StringBuffer()
      ..writeln('Nuvio sources diagnostics')
      ..writeln('title: ${widget.target.title} (tmdb ${widget.target.tmdbId})')
      ..writeln(
        'nuvio scrapers: ${_nuvioResult.streams.length} links, '
        '${_nuvioResult.completedCount}/${_nuvioResult.totalCount} done',
      );
    for (final status in _nuvioResult.statuses) {
      buffer.writeln(
        '- ${status.scraperName}: ${status.outcome.name}'
        '${status.outcome == NuvioScraperOutcome.links ? ' (${status.linkCount})' : ''}'
        '${status.message == null ? '' : ' — ${status.message}'}',
      );
    }
    return buffer.toString();
  }

  bool _showUnavailable = false;

  /// Key of the row focus currently sits on, and the section it was in when
  /// focus arrived.
  ///
  /// Probes land for seconds after the sheet opens, and each result can
  /// re-bucket a row. On TV that pulls the card out from under the user: the
  /// unavailable section is collapsed by default, so the focused row is
  /// unmounted and focus falls back to the scope root with no ring anywhere on
  /// screen. A row keeps whichever section it was in for as long as it holds
  /// focus, and moves once the user steps off it.
  String? _focusedRowKey;
  bool _focusedRowWasUnavailable = false;

  /// Autofocus is a one-shot. Rows are keyed now, so a scraper that reports a
  /// new best link mounts a fresh top-pick row; without this it would claim
  /// focus back off whatever the user had already walked to.
  bool _autofocusClaimed = false;

  /// Both actions sit on every row, so [PluginSourcesSheet.mode] decides only
  /// what activating the card body does and which rows are worth listing. PR
  /// #98 dropped the Play/Download segmented toggle but left the parameter
  /// declared and unread; callers that open the sheet to download get that
  /// behaviour back here.
  bool get _downloadMode => widget.mode == SourcesMode.download;

  void _handleRowFocusChange(_Row row, bool focused) {
    if (focused) {
      _autofocusClaimed = true;
      _focusedRowKey = row.key;
      _focusedRowWasUnavailable = _probeSaysUnavailable(row);
      return;
    }
    if (_focusedRowKey != row.key) return;
    final wasPinned = _focusedRowWasUnavailable != _probeSaysUnavailable(row);
    _focusedRowKey = null;
    // Only a row that was being held out of its section needs a rebuild.
    if (wasPinned && mounted) setState(() {});
  }

  bool _probeSaysUnavailable(_Row row) {
    // Any probe that completed and is not reachable is unavailable (HTTP error, timeout, 404, etc.)
    final probe = _probes[row.url];
    return probe != null && !probe.reachable;
  }

  bool _isRowUnavailable(_Row row) {
    if (row.key == _focusedRowKey) return _focusedRowWasUnavailable;
    return _probeSaysUnavailable(row);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final palette = GlassPalette.of(context);
    final episode = widget.episode;

    final visible = _visible;
    final providers = _allRows.map((e) => e.providerName).toSet().toList()
      ..sort();
    final nuvioCount = _nuvioResult.streams.length;

    // Counts for subtitle
    final workingCount = _allRows
        .where((r) => _probes[r.url]?.reachable == true)
        .length;
    final unavailableCount = _allRows.where(_isRowUnavailable).length;

    String subtitleText;
    if (workingCount > 0 || unavailableCount > 0) {
      subtitleText =
          '$workingCount working${unavailableCount > 0 ? ', $unavailableCount unavailable' : ''}';
    } else if (episode != null ||
        _titleOverride != null ||
        _tmdbOverride != null) {
      subtitleText = _titleOverride != null || _tmdbOverride != null
          ? 'Searching: "${_titleOverride ?? 'tmdb:$_tmdbOverride'}"'
          : 'S${episode!.season} · E${episode.episode} ${episode.name}';
    } else {
      subtitleText = _isLoading
          ? 'Searching scrapers… ${_nuvioResult.completedCount}/${_nuvioResult.totalCount}'
          : '$nuvioCount links found';
    }

    // Split visible rows into ready and unavailable
    final readyRows = <_Row>[];
    final unavailableRows = <_Row>[];
    for (final row in visible) {
      if (_isRowUnavailable(row)) {
        unavailableRows.add(row);
      } else {
        readyRows.add(row);
      }
    }

    final entries = _entriesFor(readyRows, unavailableRows);
    final rowIndexByKey = <Key, int>{
      for (var i = 0; i < entries.length; i++)
        if (entries[i] case _RowEntry(:final row)) ValueKey(row.key): i,
    };

    // Dynamic Capsule: Centered floating glass island.
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.zero,
      elevation: 0,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Center(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 580,
                    maxHeight: 680,
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          // Themed, like the add-on sheet's: a 50%-black drop
                          // under a pale panel in light mode was a bruise.
                          color: palette.paneShadow,
                          blurRadius: 50,
                          spreadRadius: 0,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // 1. LAYERED TRANSLUCENT OBSIDIAN/CHARCOAL BLACK BASE WITH BACKDROP BLUR
                          Positioned.fill(
                            child: BackdropFilter(
                              filter: ui.ImageFilter.blur(
                                sigmaX: 22.0,
                                sigmaY: 22.0,
                              ),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: palette.pane,
                                ),
                              ),
                            ),
                          ),
                          // Hairline edge on the glass. It used to be
                          // wrapped in a full-bleed ShaderMask that faded the
                          // line out over the top and bottom 15% of the
                          // panel: a BlendMode.dstIn mask costs an offscreen
                          // surface the size of the whole sheet, and what it
                          // bought was a gradient between "0.5 dp line at 12%
                          // ink" and "no line at all" - a transition between
                          // two states that are already at the edge of
                          // visible. The line itself is kept, and now closes
                          // around the top and bottom corners as well.
                          Positioned.fill(
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: palette.tint(0.12),
                                    width: 0.5,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // Main content
                          Positioned.fill(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Header Bar
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    18,
                                    14,
                                    12,
                                    4,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              'Nuvio Sources',
                                              style: theme.textTheme.titleMedium
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w700,
                                                    color: palette.ink,
                                                    letterSpacing: -0.2,
                                                  ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              subtitleText,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                    color: cs.onSurfaceVariant,
                                                    fontSize: 11.5,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      // Accessibility Search Button: Icon in accent on accent-filled circle
                                      Container(
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: cs.primary.withValues(
                                            alpha: 0.15,
                                          ),
                                        ),
                                        child: IconButton(
                                          tooltip: 'Search manually',
                                          visualDensity: VisualDensity.compact,
                                          icon: Icon(
                                            Icons.search_rounded,
                                            size: 19,
                                            color: cs.primary,
                                          ),
                                          onPressed: () =>
                                              unawaited(_searchManually()),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      // Accessibility Close Button: Icon in danger, transparent bg, danger hover/tap
                                      IconButton(
                                        tooltip: 'Close',
                                        visualDensity: VisualDensity.compact,
                                        icon: const Icon(
                                          Icons.close_rounded,
                                          size: 20,
                                          color: Color(0xFFEF4444),
                                        ),
                                        hoverColor: const Color(
                                          0xFFEF4444,
                                        ).withValues(alpha: 0.15),
                                        highlightColor: const Color(
                                          0xFFEF4444,
                                        ).withValues(alpha: 0.2),
                                        onPressed: () =>
                                            Navigator.of(context).pop(),
                                      ),
                                    ],
                                  ),
                                ),

                                // Telemetry Status Strip
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    18,
                                    4,
                                    18,
                                    4,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          _isLoading
                                              ? 'Searching scrapers… '
                                                    '${_nuvioResult.completedCount}/${_nuvioResult.totalCount}'
                                              : '$nuvioCount links found',
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                color: _isLoading
                                                    ? cs.primary
                                                    : cs.onSurfaceVariant,
                                                fontWeight: FontWeight.w600,
                                              ),
                                        ),
                                      ),
                                      if (_isLoading)
                                        SizedBox(
                                          width: 80,
                                          child: LinearProgressIndicator(
                                            value: _nuvioResult.totalCount == 0
                                                ? null
                                                : _nuvioResult.completedCount /
                                                      _nuvioResult.totalCount,
                                            minHeight: 2.5,
                                            backgroundColor: palette.tint(0.1),
                                            valueColor: AlwaysStoppedAnimation(
                                              cs.primary,
                                            ),
                                          ),
                                        )
                                      else if (_nuvioResult.hasWork)
                                        TextButton(
                                          style: TextButton.styleFrom(
                                            padding: EdgeInsets.zero,
                                            minimumSize: const Size(50, 26),
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                          ),
                                          onPressed: () => setState(
                                            () => _showDiagnostics =
                                                !_showDiagnostics,
                                          ),
                                          child: Text(
                                            _showDiagnostics
                                                ? 'Hide'
                                                : 'Details',
                                            style: const TextStyle(
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),

                                if (_showDiagnostics)
                                  _diagnosticsPanel(theme, cs),

                                // Filter Chips Rail
                                SizedBox(
                                  height: 34,
                                  child: ListView(
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                    ),
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: 6,
                                        ),
                                        child: FilterChip(
                                          visualDensity: VisualDensity.compact,
                                          label: const Text(
                                            '1080p+',
                                            style: TextStyle(fontSize: 11),
                                          ),
                                          selected: _hdOnly,
                                          selectedColor: cs.primary,
                                          labelStyle: TextStyle(
                                            fontSize: 11,
                                            color: _hdOnly
                                                ? cs.onPrimary
                                                : cs.onSurfaceVariant,
                                            fontWeight: _hdOnly
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                          ),
                                          side: BorderSide(
                                            color: _hdOnly
                                                ? Colors.transparent
                                                : palette.tint(0.15),
                                            width: 1,
                                          ),
                                          backgroundColor: Colors.transparent,
                                          onSelected: (value) =>
                                              setState(() => _hdOnly = value),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                          ),
                                        ),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: 6,
                                        ),
                                        child: FilterChip(
                                          visualDensity: VisualDensity.compact,
                                          label: const Text(
                                            'Tested',
                                            style: TextStyle(fontSize: 11),
                                          ),
                                          selected: _verifiedOnly,
                                          selectedColor: cs.primary,
                                          labelStyle: TextStyle(
                                            fontSize: 11,
                                            color: _verifiedOnly
                                                ? cs.onPrimary
                                                : cs.onSurfaceVariant,
                                            fontWeight: _verifiedOnly
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                          ),
                                          side: BorderSide(
                                            color: _verifiedOnly
                                                ? Colors.transparent
                                                : palette.tint(0.15),
                                            width: 1,
                                          ),
                                          backgroundColor: Colors.transparent,
                                          onSelected: (value) => setState(
                                            () => _verifiedOnly = value,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                          ),
                                        ),
                                      ),
                                      for (final provider in providers)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            right: 6,
                                          ),
                                          child: FilterChip(
                                            visualDensity:
                                                VisualDensity.compact,
                                            label: Text(
                                              provider,
                                              style: const TextStyle(
                                                fontSize: 11,
                                              ),
                                            ),
                                            selected: _providerFilter.contains(
                                              provider,
                                            ),
                                            selectedColor: cs.primary,
                                            labelStyle: TextStyle(
                                              fontSize: 11,
                                              color:
                                                  _providerFilter.contains(
                                                    provider,
                                                  )
                                                  ? cs.onPrimary
                                                  : cs.onSurfaceVariant,
                                              fontWeight:
                                                  _providerFilter.contains(
                                                    provider,
                                                  )
                                                  ? FontWeight.w700
                                                  : FontWeight.w500,
                                            ),
                                            side: BorderSide(
                                              color:
                                                  _providerFilter.contains(
                                                    provider,
                                                  )
                                                  ? Colors.transparent
                                                  : palette.tint(0.15),
                                              width: 1,
                                            ),
                                            backgroundColor: Colors.transparent,
                                            onSelected: (value) => setState(() {
                                              if (value) {
                                                _providerFilter.add(provider);
                                              } else {
                                                _providerFilter.remove(
                                                  provider,
                                                );
                                              }
                                            }),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),

                                const SizedBox(height: 6),

                                // Stream Source List (Structured with Top Pick, Ready, and Unavailable)
                                Expanded(
                                  child: visible.isEmpty
                                      ? Center(
                                          child: Padding(
                                            padding: const EdgeInsets.all(24),
                                            child: Text(
                                              _emptyMessage(context),
                                              textAlign: TextAlign.center,
                                              style: theme.textTheme.bodyMedium
                                                  ?.copyWith(
                                                    color: cs.onSurfaceVariant,
                                                  ),
                                            ),
                                          ),
                                        )
                                      : ListView.builder(
                                          padding: const EdgeInsets.fromLTRB(
                                            14,
                                            4,
                                            14,
                                            16,
                                          ),
                                          itemCount: entries.length,
                                          // Keeps a reordered row's element — and with it
                                          // its State and focus nodes — attached to the
                                          // same source as probes reshuffle the list.
                                          findChildIndexCallback: (key) =>
                                              rowIndexByKey[key],
                                          itemBuilder: (context, index) =>
                                              _buildEntry(entries[index], cs),
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Flattens the Top pick / Ready / Unavailable sections into the indexed
  /// list [ListView.builder] walks, carrying the gap each entry used to get
  /// from a [SizedBox] between siblings.
  List<_Entry> _entriesFor(List<_Row> ready, List<_Row> unavailable) {
    final entries = <_Entry>[];
    final topPick = ready.isEmpty ? null : ready.first;
    final rest = ready.length > 1 ? ready.sublist(1) : const <_Row>[];

    if (topPick != null) {
      entries.add(const _SectionEntry(_SectionKind.topPick, count: 1, gap: 6));
      entries.add(
        _RowEntry(
          topPick,
          isBest: true,
          autofocus: !_autofocusClaimed,
          faded: false,
          gap: 12,
        ),
      );
    }

    if (rest.isNotEmpty) {
      entries.add(
        _SectionEntry(_SectionKind.ready, count: rest.length, gap: 6),
      );
      for (var i = 0; i < rest.length; i++) {
        entries.add(
          _RowEntry(
            rest[i],
            isBest: false,
            autofocus: topPick == null && i == 0 && !_autofocusClaimed,
            faded: false,
            gap: i == rest.length - 1 ? 12 : 6,
          ),
        );
      }
    }

    if (unavailable.isNotEmpty) {
      entries.add(
        _SectionEntry(
          _SectionKind.unavailableToggle,
          count: unavailable.length,
          gap: _showUnavailable ? 6 : 0,
        ),
      );
      if (_showUnavailable) {
        for (var i = 0; i < unavailable.length; i++) {
          entries.add(
            _RowEntry(
              unavailable[i],
              isBest: false,
              autofocus: false,
              faded: true,
              gap: i == unavailable.length - 1 ? 0 : 6,
            ),
          );
        }
      }
    }

    return entries;
  }

  Widget _buildEntry(_Entry entry, ColorScheme cs) {
    switch (entry) {
      case _SectionEntry(kind: _SectionKind.topPick):
        return Padding(
          padding: EdgeInsets.only(left: 2, bottom: entry.gap),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 7,
                  vertical: 2.5,
                ),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'TOP PICK',
                  style: TextStyle(
                    color: cs.primary,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
            ],
          ),
        );

      case _SectionEntry(kind: _SectionKind.ready, :final count):
        return Padding(
          padding: EdgeInsets.only(left: 2, bottom: entry.gap),
          child: Row(
            children: [
              const Icon(
                Icons.play_circle_outline_rounded,
                size: 14,
                color: Color(0xFF10B981),
              ),
              const SizedBox(width: 6),
              Text(
                'Ready to play ($count)',
                style: const TextStyle(
                  color: Color(0xFF10B981),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        );

      case _SectionEntry(kind: _SectionKind.unavailableToggle, :final count):
        final palette = GlassPalette.of(context);
        return Padding(
          padding: EdgeInsets.only(bottom: entry.gap),
          child: DpadFocusable(
            onSelect: () =>
                setState(() => _showUnavailable = !_showUnavailable),
            child: const SizedBox.shrink(),
            builder: (context, state, _) {
              final isFocused = state.focused;
              return Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isFocused ? palette.ink : Colors.transparent,
                    width: 1.5,
                  ),
                ),
                child: InkWell(
                  // DpadFocusable already owns this stop's focus node.
                  canRequestFocus: false,
                  borderRadius: BorderRadius.circular(8),
                  onTap: () =>
                      setState(() => _showUnavailable = !_showUnavailable),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        Text(
                          '$count unavailable',
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 4),
                        AnimatedRotation(
                          turns: _showUnavailable ? 0.5 : 0.0,
                          duration: const Duration(milliseconds: 200),
                          child: Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 18,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );

      case _RowEntry(:final row):
        final Widget sourceRow = _SourceRow(
          row: row,
          probe: _probes[row.url],
          probing: _probing.contains(row.url),
          isBest: entry.isBest,
          autofocus: entry.autofocus,
          downloadMode: _downloadMode,
          onFocusChange: (focused) => _handleRowFocusChange(row, focused),
          onPlay: () => _play(row),
          onDownload: () => unawaited(_download(row)),
        );
        // The key rides the outermost widget so [findChildIndexCallback] can
        // match it, which is what keeps this row's State attached to this
        // source when the list reorders.
        return Padding(
          key: ValueKey(row.key),
          padding: EdgeInsets.only(bottom: entry.gap),
          // Always an [Opacity], never a conditional wrapper: inserting one
          // when a row fades would replace the subtree below it and take the
          // row's focus nodes with it.
          child: Opacity(opacity: entry.faded ? 0.55 : 1, child: sourceRow),
        );
    }
  }
}

/// DPad-navigable manual search dialog that allows moving seamlessly from
/// the text input down to the action buttons.
class _ManualSearchDialog extends StatefulWidget {
  final String initialText;
  final bool hasOverride;

  const _ManualSearchDialog({
    required this.initialText,
    required this.hasOverride,
  });

  @override
  State<_ManualSearchDialog> createState() => _ManualSearchDialogState();
}

class _ManualSearchDialogState extends State<_ManualSearchDialog> {
  late final TextEditingController _controller;
  late final FocusNode _textFocusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _textFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _controller.dispose();
    _textFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Search Nuvio scrapers manually'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Type a title or TMDB id (or tmdb:123) to re-point the Nuvio scrapers.',
          ),
          const SizedBox(height: 14),
          Focus(
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.arrowDown) {
                node.nextFocus();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: TextField(
              controller: _controller,
              focusNode: _textFocusNode,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Title or TMDB id',
              ),
              onSubmitted: (text) => Navigator.pop(context, text.trim()),
            ),
          ),
        ],
      ),
      actions: [
        _DpadDialogButton(
          label: 'Cancel',
          onPressed: () => Navigator.pop(context),
          isPrimary: false,
        ),
        if (widget.hasOverride)
          _DpadDialogButton(
            label: 'Reset',
            onPressed: () => Navigator.pop(context, ''),
            isPrimary: false,
          ),
        _DpadDialogButton(
          label: 'Search',
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          isPrimary: true,
        ),
      ],
    );
  }
}

class _DpadDialogButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final bool isPrimary;

  const _DpadDialogButton({
    required this.label,
    required this.onPressed,
    required this.isPrimary,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final palette = GlassPalette.of(context);

    return DpadFocusable(
      onSelect: onPressed,
      child: const SizedBox.shrink(),
      builder: (context, state, _) {
        final isFocused = state.focused;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isFocused ? palette.ink : Colors.transparent,
              width: 2,
            ),
          ),
          // FilledButton/TextButton each publish a focus node, which would
          // make every dialog button two stops on the D-pad. They expose no
          // canRequestFocus, so the subtree is excluded instead; taps still
          // work and select arrives via DpadFocusable.onSelect above.
          child: ExcludeFocus(
            child: isPrimary
                ? FilledButton(
                    onPressed: onPressed,
                    style: FilledButton.styleFrom(
                      backgroundColor: isFocused ? cs.primary : null,
                    ),
                    child: Text(label),
                  )
                : TextButton(
                    onPressed: onPressed,
                    style: TextButton.styleFrom(
                      backgroundColor: isFocused
                          ? cs.surfaceContainerHighest
                          : Colors.transparent,
                    ),
                    child: Text(label),
                  ),
          ),
        );
      },
    );
  }
}



/// Premium quality badge styled consistently with player UI badges.

class _SourceRow extends StatefulWidget {
  final _Row row;
  final LinkProbeResult? probe;
  final bool probing;
  final bool isBest;
  final bool autofocus;

  /// Activating the card body downloads instead of plays. Both chips are on
  /// the card either way.
  final bool downloadMode;

  /// Fires for the card and for its action buttons alike, so the sheet knows
  /// the user is standing here.
  final ValueChanged<bool> onFocusChange;
  final VoidCallback onPlay;
  final VoidCallback onDownload;

  const _SourceRow({
    required this.row,
    required this.probe,
    required this.probing,
    required this.isBest,
    required this.downloadMode,
    required this.onFocusChange,
    required this.onPlay,
    required this.onDownload,
    this.autofocus = false,
  });

  @override
  State<_SourceRow> createState() => _SourceRowState();
}

class _SourceRowState extends State<_SourceRow> {
  late final FocusNode _cardFocusNode;
  late final FocusNode _playFocusNode;
  late final FocusNode _downloadFocusNode;
  bool _isHovered = false;

  @override
  void initState() {
    super.initState();
    _cardFocusNode = FocusNode();
    _playFocusNode = FocusNode();
    _downloadFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _cardFocusNode.dispose();
    _playFocusNode.dispose();
    _downloadFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final row = widget.row;
    final probe = widget.probe;
    final probing = widget.probing;
    final isBest = widget.isBest;
    final onPlay = widget.onPlay;
    final onDownload = widget.onDownload;
    final palette = GlassPalette.of(context);
    final activate = widget.downloadMode && row.canDownload
        ? onDownload
        : onPlay;

    final resolution = probe?.resolutionLabel ?? row.qualityLabel;
    final size =
        probe?.sizeLabel ??
        (row.nuvio.size != null && row.nuvio.size!.trim().isNotEmpty
            ? row.nuvio.size!.trim()
            : null);

    return DpadFocusable(
      focusNode: _cardFocusNode,
      autofocus: widget.autofocus,
      onSelect: activate,
      onFocusChange: widget.onFocusChange,
      // Play sits inside the card's own rect, so no directional policy can
      // ever pick it as the target to the right; this hop has to be explicit.
      // LEFT/RIGHT between the chips resolves natively once the card holds
      // focus and [SourceCardActions] lets them into traversal.
      // The primary-focus guard stops it firing again for a RIGHT that
      // bubbled up from Download, which has nowhere further to go - without
      // it, RIGHT on Download bounces back to Play.
      onDirection: (direction) {
        if (direction != TraversalDirection.right ||
            !_cardFocusNode.hasPrimaryFocus) {
          return false;
        }
        _playFocusNode.requestFocus();
        return true;
      },
      child: const SizedBox.shrink(),
      builder: (context, state, _) {
        final isFocused = state.focused;
        return Material(
          color: isFocused ? palette.cardFocusFill : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            // One focus node per card: DpadFocusable's. A focusable InkWell
            // publishes a second node with the same rect, and traversal
            // lands on that one, leaving the card with no focus ring.
            canRequestFocus: false,
            onTap: activate,
            overlayColor: WidgetStateProperty.all(Colors.transparent),
            hoverColor: Colors.transparent,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            onHover: (hovered) {
              if (_isHovered != hovered) {
                setState(() => _isHovered = hovered);
              }
            },
            borderRadius: BorderRadius.circular(10),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                // Focus is the one state a viewer ten feet away has to read at
                // a glance, so it gets its own colour and weight rather than
                // the accent the top pick already wears permanently.
                border: Border.all(
                  color: isFocused
                      ? palette.ink
                      : (_isHovered || isBest
                            ? cs.primary
                            : palette.tint(0.08)),
                  width: isFocused ? 2 : 1.2,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Top row: Premium quality badge (left top) + tags, size, seeders, and probe badge
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            QualityBadge(resolution: resolution),
                            if (row.isHdr)
                              const SourceTag(
                                text: 'HDR',
                                color: Colors.deepPurpleAccent,
                              ),
                            if (row.isTorrent)
                              const SourceTag(text: 'P2P', color: Colors.teal),
                            if (size != null)
                              Text(
                                size,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            if (row.nuvio.seeders != null)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.people_alt_outlined,
                                    size: 12,
                                    color: cs.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    '${row.nuvio.seeders}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: cs.onSurfaceVariant,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      ProbeBadge(
                        probe: probe,
                        probing: probing,
                        isPeerToPeer: row.isTorrent,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),

                  // Source name (starts from left, uses all horizontal space)
                  Text(
                    row.providerName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: palette.ink,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 2),

                  // Description (starts from left, uses horizontal space)
                  Text(
                    row.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Bottom row: Empty space on the left, Play and Download buttons on the bottom right corner
                  SourceCardActions(
                    cardFocusNode: _cardFocusNode,
                    child: Row(
                      children: [
                        const Spacer(),
                        DpadSourceButton(
                          focusNode: _playFocusNode,
                          icon: Icons.play_arrow_rounded,
                          label: 'Play',
                          isPrimary: true,
                          tooltip: 'Play',
                          onPressed: onPlay,
                          onDirection: (direction) {
                            switch (direction) {
                              case TraversalDirection.left:
                                _cardFocusNode.requestFocus();
                                return true;
                              case TraversalDirection.right:
                                if (!row.canDownload) return false;
                                _downloadFocusNode.requestFocus();
                                return true;
                              case TraversalDirection.up:
                              case TraversalDirection.down:
                                return false;
                            }
                          },
                        ),
                        const SizedBox(width: 8),
                        DpadSourceButton(
                          focusNode: _downloadFocusNode,
                          icon: Icons.download_rounded,
                          label: 'Download now',
                          isPrimary: false,
                          tooltip: row.canDownload
                              ? 'Download now'
                              : 'Stream-only link',
                          onPressed: row.canDownload ? onDownload : null,
                          onDirection: (direction) {
                            if (direction != TraversalDirection.left) {
                              return false;
                            }
                            _playFocusNode.requestFocus();
                            return true;
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
