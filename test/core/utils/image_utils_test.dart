import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/utils/image_utils.dart';

/// A solid PNG of exactly [width] x [height], so the decode that lands in the
/// image cache can be measured in bytes.
Future<MemoryImage> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF00A0FF),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return MemoryImage(bytes!.buffer.asUint8List());
}

/// Never completes and never errors — a CDN that accepts the connection and
/// then goes quiet. Counts its listeners so the test can see whether the
/// probe let go of the stream.
class _SilentProvider extends ImageProvider<_SilentProvider> {
  final _SilentCompleter completer = _SilentCompleter();

  int get listenerCount => completer.listenerCount;

  @override
  Future<_SilentProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_SilentProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _SilentProvider key,
    ImageDecoderCallback decode,
  ) => completer;
}

class _SilentCompleter extends ImageStreamCompleter {
  int listenerCount = 0;

  @override
  void addListener(ImageStreamListener listener) {
    listenerCount++;
    super.addListener(listener);
  }

  @override
  void removeListener(ImageStreamListener listener) {
    listenerCount--;
    super.removeListener(listener);
  }
}

void main() {
  setUp(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  group('ImageUtils.isImagePortrait', () {
    testWidgets('answers from a thumbnail, not a full-size decode', (
      tester,
    ) async {
      late bool isPortrait;
      late int cachedBytes;

      // Real decoding needs real async.
      await tester.runAsync(() async {
        // A `w780` TMDB poster is 780x1170; 512x1024 is the same shape and
        // cheap to build. Undecoded-into-thumbnail this is 2 MB of bitmap to
        // answer one boolean, against a 50 MB app-wide image cache.
        final provider = await _png(512, 1024);
        isPortrait = await ImageUtils.isImagePortrait(
          'https://fake.test/poster.jpg',
          provider: provider,
        );
        cachedBytes = PaintingBinding.instance.imageCache.currentSizeBytes;
      });

      expect(isPortrait, isTrue);
      // Something was decoded and cached — otherwise the bound below would
      // pass for the wrong reason.
      expect(cachedBytes, greaterThan(0));
      // 64 px wide at 2:1 is 64 * 128 * 4 = 32 KB. The unbounded decode is
      // 512 * 1024 * 4 = 2 MB.
      expect(cachedBytes, lessThan(100 * 1024));
    });

    testWidgets('still reads landscape correctly through the thumbnail', (
      tester,
    ) async {
      late bool isPortrait;
      await tester.runAsync(() async {
        final provider = await _png(1280, 720);
        isPortrait = await ImageUtils.isImagePortrait(
          'https://fake.test/backdrop.jpg',
          provider: provider,
        );
      });
      expect(isPortrait, isFalse);
    });

    testWidgets('gives up on a stream that never answers, and lets go of it', (
      tester,
    ) async {
      final provider = _SilentProvider();
      bool? answer;

      final future = ImageUtils.isImagePortrait(
        'https://fake.test/hangs.jpg',
        provider: provider,
        timeout: const Duration(seconds: 2),
      ).then((value) => answer = value);

      await tester.pump();
      // One listener is the probe's; the image cache adds one of its own to
      // track the live image, so count the change rather than the total.
      final subscribed = provider.listenerCount;
      expect(subscribed, greaterThanOrEqualTo(1));
      expect(answer, isNull, reason: 'answered before the deadline');

      await tester.pump(const Duration(seconds: 2));

      // Without the deadline the listener stays attached for the life of the
      // process, and with it the ImageStreamCompleter and this Future.
      expect(provider.listenerCount, subscribed - 1);
      await future;
      expect(answer, isTrue, reason: 'the default is portrait');
    });
  });
}
