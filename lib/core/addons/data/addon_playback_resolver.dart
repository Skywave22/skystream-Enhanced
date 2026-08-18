import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../extensions/providers.dart' show torrentServiceProvider;
import '../models/addon_stream_source.dart';

part 'addon_playback_resolver.g.dart';

@Riverpod(keepAlive: true)
AddonPlaybackResolver addonPlaybackResolver(Ref ref) =>
    AddonPlaybackResolver(ref);

class ResolvedAddonPlayback {
  final String url;
  final Map<String, String>? headers;
  final bool viaTorrent;

  const ResolvedAddonPlayback({
    required this.url,
    this.headers,
    this.viaTorrent = false,
  });
}

class AddonPlaybackException implements Exception {
  final String message;
  const AddonPlaybackException(this.message);
  @override
  String toString() => message;
}

/// Turns an add-on stream descriptor into something the player can open.
///
/// * `url`      → used as-is, with `behaviorHints.proxyHeaders`
/// * `infoHash` → magnet (with the add-on's trackers) handed to the bundled
///   torrent server, honouring `fileIdx` for season packs
/// * `ytId` / `externalUrl` → returned for the caller to open externally
class AddonPlaybackResolver {
  AddonPlaybackResolver(this._ref);

  final Ref _ref;

  Future<ResolvedAddonPlayback> resolve(
    AddonStreamSource stream, {
    void Function(String status)? onStatus,
  }) async {
    switch (stream.kind) {
      case AddonStreamKind.direct:
        return ResolvedAddonPlayback(
          url: stream.url!,
          headers: stream.proxyHeaders,
        );

      case AddonStreamKind.torrent:
        final magnet = stream.magnetUri;
        if (magnet == null) {
          throw const AddonPlaybackException('Torrent link is incomplete.');
        }
        onStatus?.call('Starting torrent engine…');
        final torrent = _ref.read(torrentServiceProvider);
        final playUrl = await torrent.getStreamUrl(magnet);
        if (playUrl == null) {
          throw const AddonPlaybackException(
            'Could not start the torrent stream. Try another source.',
          );
        }

        final fileIdx = stream.fileIdx;
        if (fileIdx != null && fileIdx >= 0) {
          onStatus?.call('Selecting file $fileIdx…');
          try {
            final indexed = await torrent.getStreamUrlForFileIndex(fileIdx);
            if (indexed != null && indexed.isNotEmpty) {
              return ResolvedAddonPlayback(url: indexed, viaTorrent: true);
            }
          } catch (error) {
            if (kDebugMode) {
              debugPrint('[AddonPlaybackResolver] fileIdx failed: $error');
            }
          }
        }
        return ResolvedAddonPlayback(url: playUrl, viaTorrent: true);

      case AddonStreamKind.youtube:
        return ResolvedAddonPlayback(
          url: 'https://www.youtube.com/watch?v=${stream.ytId}',
        );

      case AddonStreamKind.external:
        return ResolvedAddonPlayback(url: stream.externalUrl!);

      case AddonStreamKind.unknown:
        throw const AddonPlaybackException(
          'This source contains nothing playable.',
        );
    }
  }
}
