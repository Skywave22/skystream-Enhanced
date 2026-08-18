import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../extensions/providers.dart';
import '../models/addon_stream.dart';

part 'addon_playback_resolver.g.dart';

@Riverpod(keepAlive: true)
AddonPlaybackResolver addonPlaybackResolver(Ref ref) =>
    AddonPlaybackResolver(ref);

/// What the player actually needs to start playback.
class ResolvedAddonPlayback {
  final String url;
  final Map<String, String>? headers;
  final bool viaTorrent;
  final AddonStream source;

  const ResolvedAddonPlayback({
    required this.url,
    required this.source,
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

/// Turns any add-on stream descriptor into something the player can open.
///
/// * `url`      → used as-is (with `behaviorHints.proxyHeaders`)
/// * `infoHash` → magnet is assembled (with the add-on's trackers) and handed
///   to the bundled torrent server, which exposes a local HTTP stream
/// * `ytId`     → mapped to a YouTube watch URL for the external handler
/// * `externalUrl` → returned untouched; the caller opens it in a browser
class AddonPlaybackResolver {
  AddonPlaybackResolver(this._ref);

  final Ref _ref;

  Future<ResolvedAddonPlayback> resolve(
    AddonStream stream, {
    void Function(String status)? onStatus,
  }) async {
    switch (stream.kind) {
      case AddonStreamKind.direct:
        return ResolvedAddonPlayback(
          url: stream.url!,
          headers: stream.proxyHeaders,
          source: stream,
        );

      case AddonStreamKind.torrent:
        onStatus?.call('Starting torrent engine…');
        final magnet = stream.magnetUri;
        if (magnet == null) {
          throw const AddonPlaybackException('Torrent link is incomplete.');
        }
        final torrent = _ref.read(torrentServiceProvider);
        final playUrl = await torrent.getStreamUrl(magnet);
        if (playUrl == null) {
          throw const AddonPlaybackException(
            'Could not start the torrent stream. Try another source.',
          );
        }

        // Torrent add-ons address a specific file inside multi-file torrents
        // (typical for season packs); honour fileIdx when present.
        final fileIdx = stream.fileIdx;
        if (fileIdx != null && fileIdx >= 0) {
          onStatus?.call('Selecting file $fileIdx…');
          try {
            final indexed = await torrent.getStreamUrlForFileIndex(fileIdx);
            if (indexed != null && indexed.isNotEmpty) {
              return ResolvedAddonPlayback(
                url: indexed,
                source: stream,
                viaTorrent: true,
              );
            }
          } catch (error) {
            if (kDebugMode) {
              debugPrint('[AddonPlaybackResolver] fileIdx failed: $error');
            }
          }
        }
        return ResolvedAddonPlayback(
          url: playUrl,
          source: stream,
          viaTorrent: true,
        );

      case AddonStreamKind.youtube:
        return ResolvedAddonPlayback(
          url: 'https://www.youtube.com/watch?v=${stream.ytId}',
          source: stream,
        );

      case AddonStreamKind.external:
        return ResolvedAddonPlayback(url: stream.externalUrl!, source: stream);

      case AddonStreamKind.unknown:
        throw const AddonPlaybackException(
          'This source does not contain anything playable.',
        );
    }
  }
}
