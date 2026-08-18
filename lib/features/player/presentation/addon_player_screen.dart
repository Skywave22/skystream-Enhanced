import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../core/addons/addon_manager.dart';
import '../../../core/addons/models/addon_stream.dart';
import '../../../core/addons/services/addon_playback_resolver.dart';
import '../../../core/addons/services/addon_subtitle_service.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/providers.dart';
import '../../../core/models/torrent_status.dart';
import '../../../core/services/torrent_service.dart';
import '../../../core/storage/history_repository.dart';
import '../../../core/utils/file_size_formatter.dart';
import '../../../core/utils/memory_tuning.dart';

/// Dedicated player for Stremio add-on sources.
///
/// The main [PlayerScreen] is wired to the plugin pipeline (JS providers,
/// plugin stream lists, plugin subtitle providers). Add-on playback has a
/// different shape — magnet/`infoHash` links that must go through the bundled
/// torrent server, `proxyHeaders`, per-stream subtitle lists and binge groups —
/// so it gets its own lean surface here instead of bending the existing one.
class AddonPlayerScreen extends ConsumerStatefulWidget {
  final MultimediaItem item;
  final Episode? episode;
  final List<AddonStream> streams;
  final int initialIndex;

  /// Stremio content type/ids, used to pull subtitles from add-ons that
  /// implement the `subtitles` resource.
  final String type;
  final String? contentId;
  final String? videoId;

  const AddonPlayerScreen({
    super.key,
    required this.item,
    required this.streams,
    this.episode,
    this.initialIndex = 0,
    this.type = 'movie',
    this.contentId,
    this.videoId,
  });

  @override
  ConsumerState<AddonPlayerScreen> createState() => _AddonPlayerScreenState();
}

class _AddonPlayerScreenState extends ConsumerState<AddonPlayerScreen> {
  late final Player _player;
  late final VideoController _controller;

  StreamSubscription<String>? _errorSub;
  Timer? _torrentTimer;
  Timer? _progressTimer;

  // Captured in initState: dispose() must not touch providers through `ref`
  // after the element is unmounted.
  late final TorrentService _torrent;
  late final HistoryRepository _history;
  bool _usedTorrent = false;

  int _index = 0;
  bool _resolving = true;
  bool _showChrome = true;
  String _status = 'Preparing source…';
  String? _error;
  TorrentStatus? _torrentStatus;
  AddonSubtitle? _activeSubtitle;
  List<AddonSubtitle> _addonSubtitles = const [];
  bool _loadingSubtitles = false;
  BoxFit _fit = BoxFit.contain;
  Timer? _chromeTimer;
  bool _resumeApplied = false;
  bool _disposed = false;

  AddonStream get _current => widget.streams.isEmpty
      ? const AddonStream(addonId: '', addonName: 'Add-on')
      : widget.streams[_index.clamp(0, widget.streams.length - 1)];

  @override
  void initState() {
    super.initState();
    MediaKit.ensureInitialized();
    _torrent = ref.read(torrentServiceProvider);
    _history = ref.read(historyRepositoryProvider);
    _index = widget.initialIndex.clamp(
      0,
      widget.streams.isEmpty ? 0 : widget.streams.length - 1,
    );

    _player = Player(
      configuration: PlayerConfiguration(
        // Torrent streams arrive out of order and want a bigger window; direct
        // links do not. Sized per platform so the Windows build stays lean.
        bufferSize: MemoryTuning.playerBufferBytes(
          torrent: widget.streams.isNotEmpty &&
              widget.streams[widget.initialIndex.clamp(
                0,
                widget.streams.length - 1,
              )].isTorrent,
        ),
        title: 'SkyStream Add-ons',
      ),
    );
    _controller = VideoController(_player);

    if (_player.platform is NativePlayer) {
      final native = _player.platform as NativePlayer;
      unawaited(native.setProperty('network-timeout', '120'));
      unawaited(native.setProperty('force-seekable', 'yes'));
    }

    _errorSub = _player.stream.error.listen((message) {
      if (!mounted) return;
      setState(() => _error = message);
    });

    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      unawaited(
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]),
      );
    }
    unawaited(WakelockPlus.enable());

    _progressTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _saveProgress(),
    );

    unawaited(_load());
    _armChromeTimer();
  }

  @override
  void dispose() {
    _disposed = true;
    _saveProgress();
    _errorSub?.cancel();
    _torrentTimer?.cancel();
    _progressTimer?.cancel();
    _chromeTimer?.cancel();
    unawaited(_player.dispose());
    if (_usedTorrent) unawaited(_torrent.stop());
    unawaited(WakelockPlus.disable());
    MemoryTuning.releaseDroppableMemory();
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      unawaited(
        SystemChrome.setPreferredOrientations(DeviceOrientation.values),
      );
    }
    super.dispose();
  }

  void _armChromeTimer() {
    _chromeTimer?.cancel();
    _chromeTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showChrome = false);
    });
  }

  void _saveProgress() {
    try {
      final position = _player.state.position.inMilliseconds;
      final duration = _player.state.duration.inMilliseconds;
      if (position <= 0 || duration <= 0) return;
      final episode = widget.episode;
      unawaited(
        _history
            .saveProgress(
              widget.item,
              position,
              duration,
              lastStreamUrl: _current.url,
              lastEpisodeUrl: episode?.url,
              season: episode?.season,
              episode: episode?.episode,
              episodeTitle: episode?.name,
              episodePosterUrl: episode?.posterUrl,
            ),
      );
    } catch (_) {
      // Progress is best-effort; never let it break playback.
    }
  }

  Future<void> _load() async {
    if (widget.streams.isEmpty) {
      setState(() {
        _resolving = false;
        _error = 'No add-on stream was provided.';
      });
      return;
    }

    setState(() {
      _resolving = true;
      _error = null;
      _status = _current.isTorrent
          ? 'Connecting to peers…'
          : 'Opening stream…';
    });

    try {
      final resolved = await ref
          .read(addonPlaybackResolverProvider)
          .resolve(
            _current,
            onStatus: (status) {
              if (mounted) setState(() => _status = status);
            },
          );

      if (!mounted) return;

      if (_current.kind == AddonStreamKind.external ||
          _current.kind == AddonStreamKind.youtube) {
        setState(() {
          _resolving = false;
          _error =
              'This source opens outside the app:\n${resolved.url}';
        });
        return;
      }

      await _player.open(
        Media(resolved.url, httpHeaders: resolved.headers),
        play: true,
      );

      if (resolved.viaTorrent) {
        _usedTorrent = true;
        _startTorrentPolling();
      } else {
        _torrentTimer?.cancel();
        _torrentStatus = null;
      }

      unawaited(_restoreProgress());

      final subtitle = _current.subtitles.isNotEmpty
          ? _current.subtitles.first
          : null;
      if (subtitle != null) {
        await _applySubtitle(subtitle);
      }
      unawaited(_loadAddonSubtitles());

      if (mounted) setState(() => _resolving = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _error = error.toString();
      });
    }
  }

  /// Seeks back to where the user left off. Waits for a real duration first —
  /// mpv reports 0 until the demuxer has parsed the container.
  Future<void> _restoreProgress() async {
    if (_resumeApplied) return;
    final episode = widget.episode;
    final saved = episode == null
        ? _history.getPosition(widget.item.url)
        : _history.getEpisodePosition(
            episode.url,
            mainUrl: widget.item.url,
            season: episode.season,
            episode: episode.episode,
          );
    if (saved <= 10000) return;

    for (var attempt = 0; attempt < 20; attempt++) {
      if (!mounted || _disposed) return;
      final duration = _player.state.duration.inMilliseconds;
      if (duration > 0) {
        // Don't resume if the user was basically finished.
        if (saved < duration * 0.97) {
          _resumeApplied = true;
          await _player.seek(Duration(milliseconds: saved));
        }
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  /// Add-ons that implement the `subtitles` resource (OpenSubtitles v3, …) are
  /// asked in the background so the subtitle menu fills in while playback has
  /// already started.
  Future<void> _loadAddonSubtitles() async {
    final contentId = widget.contentId;
    if (contentId == null || contentId.isEmpty) return;

    final ids = <String>[
      if (widget.videoId != null && widget.videoId!.isNotEmpty) widget.videoId!,
      if (widget.episode != null)
        '${contentId.split(':').first}:${widget.episode!.season}:${widget.episode!.episode}'
      else
        contentId,
    ];

    if (mounted) setState(() => _loadingSubtitles = true);
    try {
      final subs = await ref
          .read(addonSubtitleServiceProvider)
          .fetch(
            addons: ref.read(addonManagerProvider).enabled,
            type: widget.type,
            ids: ids,
            videoSize: _current.videoSize,
            filename: _current.filename,
          );
      if (!mounted || _disposed) return;
      setState(() {
        _addonSubtitles = subs;
        _loadingSubtitles = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingSubtitles = false);
    }
  }

  void _startTorrentPolling() {
    _torrentTimer?.cancel();
    _torrentTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final status = await _torrent.getCurrentStatus();
      if (!mounted) return;
      setState(() => _torrentStatus = status);
    });
  }

  Future<void> _applySubtitle(AddonSubtitle? subtitle) async {
    try {
      if (subtitle == null) {
        await _player.setSubtitleTrack(SubtitleTrack.no());
      } else {
        await _player.setSubtitleTrack(
          SubtitleTrack.uri(
            subtitle.url,
            title: subtitle.lang,
            language: subtitle.lang,
          ),
        );
      }
      if (mounted) setState(() => _activeSubtitle = subtitle);
    } catch (_) {
      // Ignore: a broken subtitle must not interrupt video playback.
    }
  }

  Future<void> _switchTo(int index) async {
    if (index == _index) return;
    // Keep the current position when hopping to another source for the same
    // title: save first, then let _restoreProgress put us back.
    _saveProgress();
    setState(() {
      _index = index;
      _resumeApplied = false;
    });
    await _load();
  }

  void _toggleChrome() {
    setState(() => _showChrome = !_showChrome);
    if (_showChrome) _armChromeTimer();
  }

  void _openSourceSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: widget.streams.length,
            itemBuilder: (context, index) {
              final stream = widget.streams[index];
              return ListTile(
                selected: index == _index,
                leading: CircleAvatar(
                  child: Text(
                    stream.qualityLabel,
                    style: const TextStyle(fontSize: 10),
                  ),
                ),
                title: Text(
                  stream.sourceLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  [
                    stream.addonName,
                    if (stream.sizeLabel != null) stream.sizeLabel!,
                    if (stream.seeders != null) '${stream.seeders} seeders',
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_switchTo(index));
                },
              );
            },
          ),
        );
      },
    );
  }

  List<AddonSubtitle> get _allSubtitles {
    final seen = <String>{};
    final out = <AddonSubtitle>[];
    for (final sub in [..._current.subtitles, ..._addonSubtitles]) {
      if (sub.url.isEmpty) continue;
      if (seen.add(sub.url)) out.add(sub);
    }
    return out;
  }

  void _openSubtitleSheet() {
    final subtitles = _allSubtitles;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.subtitles_off_rounded),
                title: const Text('Off'),
                selected: _activeSubtitle == null,
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_applySubtitle(null));
                },
              ),
              if (_loadingSubtitles)
                const ListTile(
                  leading: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  title: Text('Looking for subtitles in your add-ons…'),
                ),
              if (subtitles.isEmpty && !_loadingSubtitles)
                const ListTile(
                  enabled: false,
                  title: Text(
                    'No subtitles. Install a subtitle add-on such as '
                    'OpenSubtitles v3.',
                  ),
                ),
              for (final subtitle in subtitles)
                ListTile(
                  leading: const Icon(Icons.subtitles_rounded),
                  title: Text(prettySubtitleLanguage(subtitle.lang)),
                  selected: _activeSubtitle?.url == subtitle.url,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(_applySubtitle(subtitle));
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  String get _title {
    final episode = widget.episode;
    if (episode == null) return widget.item.title;
    return '${widget.item.title} · S${episode.season}E${episode.episode}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleChrome,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Video(
                controller: _controller,
                controls: AdaptiveVideoControls,
                fit: _fit,
                filterQuality: FilterQuality.medium,
              ),
              if (_resolving || _error != null)
                _overlay(theme)
              else if (_torrentStatus != null)
                Positioned(
                  left: 16,
                  bottom: 96,
                  child: _torrentBadge(theme, _torrentStatus!),
                ),
              if (_showChrome) _topBar(theme),
            ],
          ),
        ),
      );
  }

  Widget _overlay(ThemeData theme) {
    final error = _error;
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.75),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (error == null) ...[
                const CircularProgressIndicator(),
                const SizedBox(height: 18),
                Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
                const SizedBox(height: 8),
                Text(
                  _current.sourceLabel,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                ),
              ] else ...[
                const Icon(
                  Icons.error_outline_rounded,
                  color: Colors.white70,
                  size: 42,
                ),
                const SizedBox(height: 14),
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 12,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: () => unawaited(_load()),
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Retry'),
                    ),
                    if (widget.streams.length > 1)
                      OutlinedButton.icon(
                        onPressed: () => unawaited(
                          _switchTo((_index + 1) % widget.streams.length),
                        ),
                        icon: const Icon(Icons.skip_next_rounded),
                        label: const Text('Next source'),
                      ),
                    TextButton(
                      onPressed: () => context.pop(),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _torrentBadge(ThemeData theme, TorrentStatus status) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.bolt_rounded, color: Colors.amber, size: 16),
          const SizedBox(width: 6),
          Text(
            '${status.speedString} · ${status.seeds} seeds · '
            '${formatFileSize(status.bytesRead, fractionDigits: 1)}',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _topBar(ThemeData theme) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.75),
              Colors.transparent,
            ],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                onPressed: () => context.pop(),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '${_current.addonName} · ${_current.qualityLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Aspect ratio',
                icon: const Icon(Icons.aspect_ratio_rounded, color: Colors.white),
                onPressed: () {
                  setState(() {
                    _fit = _fit == BoxFit.contain
                        ? BoxFit.cover
                        : _fit == BoxFit.cover
                        ? BoxFit.fill
                        : BoxFit.contain;
                  });
                },
              ),
              IconButton(
                tooltip: 'Subtitles',
                icon: const Icon(Icons.subtitles_rounded, color: Colors.white),
                onPressed: _openSubtitleSheet,
              ),
              if (widget.streams.length > 1)
                IconButton(
                  tooltip: 'Sources',
                  icon: const Icon(Icons.playlist_play_rounded, color: Colors.white),
                  onPressed: _openSourceSheet,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
