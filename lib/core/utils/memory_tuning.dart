import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Central place for the memory knobs that decide SkyStream's resident set.
///
/// Desktop builds (especially the Windows installer build) were the worst
/// offenders: a 100 MB Flutter image cache plus a 128 MB mpv demuxer buffer
/// plus a 32 MB probe buffer meant the process could sit above 700 MB while
/// idling on a poster grid. Everything that used to be a hard-coded constant
/// now goes through here, sized per platform, with an explicit "release
/// everything droppable" hook for memory-pressure callbacks.
class MemoryTuning {
  const MemoryTuning._();

  static bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// Decoded-image cache. Posters dominate SkyStream's heap, so this is the
  /// single most effective lever.
  static void applyImageCacheLimits({bool isTv = false}) {
    final cache = PaintingBinding.instance.imageCache;
    if (isDesktop) {
      // Desktop windows are large but the grid recycles aggressively; 32 MB
      // holds roughly two screens of posters.
      cache.maximumSize = 120;
      cache.maximumSizeBytes = 32 * 1024 * 1024;
    } else if (isTv) {
      cache.maximumSize = 100;
      cache.maximumSizeBytes = 28 * 1024 * 1024;
    } else {
      cache.maximumSize = 150;
      cache.maximumSizeBytes = 40 * 1024 * 1024;
    }
  }

  /// mpv demuxer buffer. Torrent playback genuinely benefits from a big
  /// read-ahead window; plain HTTP/HLS does not.
  static int playerBufferBytes({bool torrent = false}) {
    if (isDesktop) {
      return torrent ? 32 * 1024 * 1024 : 16 * 1024 * 1024;
    }
    return torrent ? 64 * 1024 * 1024 : 32 * 1024 * 1024;
  }

  /// `demuxer-lavf-probesize`. 32 MB was chosen to catch late audio tracks;
  /// 8 MB does the same job for every mainstream container while keeping a
  /// quarter of the memory.
  static int demuxerProbeSizeBytes() =>
      isDesktop ? 8 * 1024 * 1024 : 16 * 1024 * 1024;

  /// How many JSON metadata responses the HTTP layer may hold.
  static int metadataCacheEntries() => isDesktop ? 90 : 160;

  /// How many add-on responses (manifests/catalogs/streams) stay resident.
  static int addonCacheEntries() => isDesktop ? 90 : 180;

  /// Drops every cache that can be rebuilt from the network/disk. Wired to
  /// `WidgetsBindingObserver.didHaveMemoryPressure` and to leaving the player.
  static void releaseDroppableMemory() {
    final cache = PaintingBinding.instance.imageCache;
    cache.clearLiveImages();
    cache.clear();
    if (kDebugMode) {
      debugPrint('[MemoryTuning] dropped image caches');
    }
  }
}
