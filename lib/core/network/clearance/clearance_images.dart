/// Posters and other artwork from a site behind a bot check.
///
/// Cloudflare answers an image request that carries no clearance with its
/// check page, so on a site that checks every request its posters never show.
/// The clearance a plugin's own request earned for that site goes with them,
/// as it goes with the player's stream requests ([Clearance.withClearance]);
/// an image never starts a check of its own, which would open hidden pages,
/// or the check sheet, for a picture.
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'clearance.dart';

/// The image cache's way of fetching a file, with the clearance of each
/// image's site on its request.
class ClearanceImageFileService extends FileService {
  ClearanceImageFileService({FileService? inner})
    : _inner = inner ?? HttpFileService();

  final FileService _inner;

  @override
  int get concurrentFetches => _inner.concurrentFetches;

  @override
  set concurrentFetches(int value) => _inner.concurrentFetches = value;

  @override
  Future<FileServiceResponse> get(String url, {Map<String, String>? headers}) {
    final uri = Uri.tryParse(url);
    final sent = headers ?? const <String, String>{};
    return _inner.get(
      url,
      headers: uri == null || uri.host.isEmpty
          ? sent
          : Clearance.instance.withClearance(uri, sent),
    );
  }
}

/// The app's image cache, fetching through [ClearanceImageFileService].
///
/// On the default cache's key, so its folder - the one Settings clears - and
/// the images already in it stay as they were; an [ImageCacheManager], for
/// the resized copies image widgets ask for.
class ClearanceImageCacheManager extends CacheManager with ImageCacheManager {
  ClearanceImageCacheManager()
    : super(
        Config(
          DefaultCacheManager.key,
          // Cap the on-disk image cache so browsing dozens of posters and
          // backdrops cannot grow it without bound. `stalePeriod` (default 7
          // days) evicts old entries; `maxNrOfCacheObjects` caps the number
          // of cached artworks so disk use stays bounded too.
          maxNrOfCacheObjects: 500,
          fileService: ClearanceImageFileService(),
        ),
      );

  /// The same, keeping its records in [repo] and its files in [fileSystem].
  @visibleForTesting
  ClearanceImageCacheManager.storedIn(
    CacheInfoRepository repo,
    FileSystem fileSystem,
  ) : super(
        Config(
          DefaultCacheManager.key,
          repo: repo,
          fileSystem: fileSystem,
          fileService: ClearanceImageFileService(),
        ),
      );
}

/// Makes [images] - by default a [ClearanceImageCacheManager] - the cache
/// every CachedNetworkImage uses unless it brings its own. Called in main
/// before the first frame: a cache is picked when an image is asked for.
void installClearanceImageCache([BaseCacheManager? images]) {
  CachedNetworkImageProvider.defaultCacheManager =
      images ?? ClearanceImageCacheManager();
}
