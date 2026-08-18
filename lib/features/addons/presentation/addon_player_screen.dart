import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../core/addons/data/addon_playback_resolver.dart';
import '../../../core/addons/data/addon_repository.dart';
import '../../../core/addons/data/addon_stream_service.dart';
import '../../../core/addons/data/addon_subtitle_service.dart';
import '../../../core/addons/models/addon_stream_source.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/providers.dart' show torrentServiceProvider;
import '../../../core/models/torrent_status.dart';
import '../../../core/services/torrent_service.dart';
import '../../../core/storage/history_repository.dart';
import '../../../core/utils/file_size_formatter.dart';

/// Player used for add-on playback.
///
/// It is separate from the plugin player on purpose: add-on links need
/// `proxyHeaders`, magnet/`infoHash` handling through the bundled torrent
/// server and add-on subtitle tracks, and none of that should leak into the
/// existing plugin pipeline (or vice-versa).
class AddonPlayerScreen extends ConsumerStatefulWidget {
  final MultimediaItem item;
  final Episode? episode;
  final AddonStreamRequest request;
  final List<AddonStreamSource> streams;
  final int initialIndex;

  const AddonPlayerScreen({
    super.key,
    required this.item,
    required this.request,
    required this.streams,
    this.episode,
    this.initialIndex = 0,
  });

  @override
  ConsumerState<AddonPlayerScreen> createState() => _AddonPlayerScreenState();
}

class _AddonPlayerScreenState extends ConsumerState<AddonPlayerScreen> {
  late final Player _player;
  late final VideoController _controller;
  late final TorrentService _torrent;
  late final HistoryRepository _history;

  StreamSubscription<String>? _errorSub;
  Timer? _torrentTimer;
  Timer? _progressTimer;
  Timer? _chromeTimer;

  int _index = 0;
  bool _disposed = false;
  bool _resolving = true;
  bool _usedTorrent = false;
  bool _showChrome = true;
  bool _resumeApplied = false;
  bool _loadingSubtitles = false;
  String _status = 'Preparing source…';
  String? _error;
  TorrentStatus? _torrentStatus;
  List<AddonSubtitleTrack> _addonSubtitles = const [];
  AddonSubtitleTrack? _activeSubtitle;
  BoxFit _fit = BoxFit.contain;

  AddonStreamSource get _current =>
      widget.streams[_index.clamp(0, widget.streams.length - 1)];

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

    final wantsTorrent =
        widget.streams.isNotEmpty && widget.streams[_index].isTorrent;
    _player = Player(
      configuration: PlayerConfiguration(
        // Torrent playback wants a large read-ahead window; direct links do
        // not, and an oversized buffer is pure resident memory.
        bufferSize: wantsTorrent ? 48 * 1024 * 1024 : 16 * 1024 * 1024,
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
    _armChromeTimer();
    unawaited(_load());
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
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
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
        _history.saveProgress(
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
      // Progress is best-effort.
    }
  }

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
        if (saved < duration * 0.97) {
          _resumeApplied = true;
          await _player.seek(Duration(milliseconds: saved));
        }
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
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
      _status = _current.isTorrent ? 'Connecting to peers…' : 'Opening stream…';
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
      if (!mounted || _disposed) return;

      if (!_current.isPlayable) {
        setState(() {
          _resolving = false;
          _error = 'This source opens outside the app:\n${resolved.url}';
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

      if (_current.subtitles.isNotEmpty) {
        await _applySubtitle(_current.subtitles.first);
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

  void _startTorrentPolling() {
    _torrentTimer?.cancel();
    _torrentTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final status = await _torrent.getCurrentStatus();
      if (!mounted || _disposed) return;
      setState(() => _torrentStatus = status);
    });
  }

  Future<void> _loadAddonSubtitles() async {
    if (mounted) setState(() => _loadingSubtitles = true);
    try {
      final subs = await ref
          .read(addonSubtitleServiceProvider)
          .fetch(
            addons: ref.read(addonRepositoryProvider).enabled,
            request: widget.request,
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

  List<AddonSubtitleTrack> get _allSubtitles {
    final seen = <String>{};
    final out = <AddonSubtitleTrack>[];
    for (final sub in [..._current.subtitles, ..._addonSubtitles]) {
      if (sub.url.isEmpty) continue;
      if (seen.add(sub.url)) out.add(sub);
    }
    return out;
  }

  Future<void> _applySubtitle(AddonSubtitleTrack? subtitle) async {
    try {
      if (subtitle == null) {
        await _player.setSubtitleTrack(SubtitleTrack.no());
      } else {
        await _player.setSubtitleTrack(
          SubtitleTrack.uri(
            subtitle.url,
            title: subtitle.label,
            language: subtitle.lang,
          ),
        );
      }
      if (mounted) setState(() => _activeSubtitle = subtitle);
    } catch (_) {
      // A broken subtitle must never interrupt playback.
    }
  }

  Future<void> _switchTo(int index) async {
    if (index == _index) return;
    _saveProgress();
    setState(() {
      _index = index;
      _resumeApplied = false;
    });
    await _load();
  }

  void _openSourceSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) => SafeArea(
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
                stream.headline,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  stream.addonName,
                  if (stream.sizeLabel != null) stream.sizeLabel!,
                  if (stream.seeders != null) '${stream.seeders} seeders',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                unawaited(_switchTo(index));
              },
            );
          },
        ),
      ),
    );
  }

  void _openSubtitleSheet() {
    final subtitles = _allSubtitles;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) => SafeArea(
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
                title: Text('Looking for subtitles…'),
              ),
            if (subtitles.isEmpty && !_loadingSubtitles)
              const ListTile(
                enabled: false,
                title: Text('No subtitles found for this title'),
              ),
            for (final subtitle in subtitles)
              ListTile(
                leading: const Icon(Icons.subtitles_rounded),
                title: Text(subtitle.label),
                subtitle: Text(subtitle.addonName),
                selected: _activeSubtitle?.url == subtitle.url,
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_applySubtitle(subtitle));
                },
              ),
          ],
        ),
      ),
    );
  }

  String get _title {
    final episode = widget.episode;
    if (episode == null) return widget.item.title;
    return '${widget.item.title} · S${episode.season}E${episode.episode}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() => _showChrome = !_showChrome);
          if (_showChrome) _armChromeTimer();
        },
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
              _overlay()
            else if (_torrentStatus != null)
              Positioned(
                left: 16,
                bottom: 96,
                child: _torrentBadge(_torrentStatus!),
              ),
            if (_showChrome) _topBar(),
          ],
        ),
      ),
    );
  }

  Widget _overlay() {
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
                const SizedBox(height: 6),
                Text(
                  _current.headline,
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
                      onPressed: () => Navigator.of(context).maybePop(),
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

  Widget _torrentBadge(TorrentStatus status) {
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

  Widget _topBar() {
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
            colors: [Colors.black.withValues(alpha: 0.75), Colors.transparent],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
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
                icon: const Icon(
                  Icons.aspect_ratio_rounded,
                  color: Colors.white,
                ),
                onPressed: () => setState(() {
                  _fit = _fit == BoxFit.contain
                      ? BoxFit.cover
                      : _fit == BoxFit.cover
                      ? BoxFit.fill
                      : BoxFit.contain;
                }),
              ),
              IconButton(
                tooltip: 'Subtitles',
                icon: const Icon(Icons.subtitles_rounded, color: Colors.white),
                onPressed: _openSubtitleSheet,
              ),
              if (widget.streams.length > 1)
                IconButton(
                  tooltip: 'Sources',
                  icon: const Icon(
                    Icons.playlist_play_rounded,
                    color: Colors.white,
                  ),
                  onPressed: _openSourceSheet,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
