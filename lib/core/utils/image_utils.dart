import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import 'package:cached_network_image/cached_network_image.dart';

class ImageUtils {
  /// Width / height of a TMDB poster (`w500` is 500x750, `w780` is 780x1170).
  static const double posterAspectRatio = 2 / 3;

  /// Width / height of a TMDB backdrop (`w1280` is 1280x720, `original` is
  /// 1920x1080 or 3840x2160). Every TMDB backdrop is 16:9.
  static const double backdropAspectRatio = 16 / 9;

  /// The `memCacheWidth` for artwork painted with [BoxFit.cover] into a box of
  /// [width] x [height] LOGICAL pixels.
  ///
  /// The raster scale is read off [View.of], not off [MediaQuery]: the scale
  /// the compositor rasterises at comes from `ViewConfiguration.fromView`, so
  /// a `MediaQuery` shim cannot change it, and `main.dart` clamps the
  /// MediaQuery ratio to 1.0 on television — anything sizing a decode off
  /// `MediaQuery.devicePixelRatioOf` there asks for 960 px against a panel
  /// rasterising at 1920 px and gets upscaled 2x.
  ///
  /// Cover crops, so the box width alone can under-ask. Cover scales by
  /// `max(boxW/srcW, boxH/srcH)`; when the box is taller in aspect than the
  /// source, the height drives the scale and the decode has to be
  /// `boxH * srcAspect` wide. [sourceAspectRatio] is the artwork's own
  /// width/height ([posterAspectRatio] or [backdropAspectRatio]).
  ///
  /// Over-asking is safe and under-asking is not: `memCacheWidth` reaches the
  /// decoder through [ResizeImage], which preserves aspect ratio and does not
  /// upscale, so a bound above the source's own width is simply ignored.
  ///
  /// Returns null (no bound) when [width] is not usable, which is the same
  /// behaviour as not passing `memCacheWidth` at all.
  static int? coverDecodeWidth(
    BuildContext context, {
    required double width,
    double? height,
    required double sourceAspectRatio,
  }) {
    if (!width.isFinite || width <= 0) return null;

    var logicalWidth = width;
    if (height != null && height.isFinite && height > 0) {
      logicalWidth = math.max(logicalWidth, height * sourceAspectRatio);
    }

    final physicalWidth = logicalWidth * View.of(context).devicePixelRatio;
    if (!physicalWidth.isFinite || physicalWidth <= 0) return null;
    return physicalWidth.round();
  }

  /// Decode width of the [isImagePortrait] probe. The answer is one boolean
  /// and 64 px keeps the aspect ratio readable to ~1.5%, so a full-size decode
  /// would buy nothing.
  static const int _probeDecodeWidth = 64;

  /// Whether the image at [url] is portrait (height >= width).
  ///
  /// Returns `true` by default if the URL is empty, the image fails to load,
  /// or nothing has arrived within [timeout].
  ///
  /// [provider] is for tests; production always probes the network image.
  static Future<bool> isImagePortrait(
    String url, {
    ImageProvider? provider,
    Duration timeout = const Duration(seconds: 15),
  }) {
    if (url.isEmpty) return Future.value(true);

    final completer = Completer<bool>();
    // ResizeImage, not the raw provider: this decodes a thumbnail into the
    // shared image cache instead of the poster at source resolution.
    final stream = ResizeImage(
      provider ?? CachedNetworkImageProvider(url),
      width: _probeDecodeWidth,
    ).resolve(const ImageConfiguration());

    late final ImageStreamListener listener;
    Timer? deadline;

    void finish(bool isPortrait) {
      deadline?.cancel();
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.complete(isPortrait);
    }

    listener = ImageStreamListener(
      (ImageInfo info, bool _) {
        finish(info.image.height >= info.image.width);
      },
      onError: (dynamic exception, StackTrace? stackTrace) {
        finish(true); // default to portrait on error
      },
    );

    // A CDN that accepts the connection and then never answers neither
    // completes nor errors, and the provider carries no timeout of its own, so
    // without this the listener, the ImageStreamCompleter, its bytes and this
    // Future are retained for the life of the process.
    deadline = Timer(timeout, () => finish(true));

    stream.addListener(listener);
    return completer.future;
  }
}
