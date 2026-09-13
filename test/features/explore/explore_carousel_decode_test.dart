import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/explore/presentation/widgets/explore_carousel.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// A 1080p television: 960x540 logical at a raster scale of 2. TMDB hands this
/// device `original` backdrops (tmdb_config.dart) — 1920x1080 at best,
/// 3840x2160 for popular titles — against a 50 MB image cache.
const double _tvDevicePixelRatio = 2.0;
const Size _tvPhysicalSize = Size(1920, 1080);

/// A phone in portrait: 411x915 logical at 3. The carousel hero is 60% of the
/// window height here, which makes the slide box far TALLER in aspect than a
/// 16:9 backdrop — so cover is driven by the height, and a bound taken from
/// the window width alone would decode a third of the pixels the phone paints.
const double _phoneDevicePixelRatio = 3.0;
const Size _phonePhysicalSize = Size(1233, 2745);

/// Reproduces the television branch of `main.dart`'s MaterialApp.builder: the
/// whole app under a MediaQuery whose devicePixelRatio is clamped to 1.0.
/// It cannot change the raster scale, so a decode read from MediaQuery asks
/// for half the pixels the panel paints.
class _TvDensityClamp extends StatelessWidget {
  const _TvDensityClamp({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(devicePixelRatio: 1.0, textScaler: TextScaler.noScaling),
      child: child,
    );
  }
}

MultimediaItem _movie(int i) => MultimediaItem(
  title: 'Title $i',
  url: 'https://fake.test/$i',
  posterUrl: '',
  bannerUrl: '',
  contentType: MultimediaContentType.movie,
);

Future<void> _pumpCarousel(
  WidgetTester tester, {
  required Size physicalSize,
  required double devicePixelRatio,
  bool clampDensity = false,
}) async {
  tester.view.devicePixelRatio = devicePixelRatio;
  tester.view.physicalSize = physicalSize;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        builder: clampDensity
            ? (context, child) => _TvDensityClamp(child: child!)
            : null,
        home: Scaffold(
          body: ExploreCarousel(
            movies: List<MultimediaItem>.generate(7, _movie),
          ),
        ),
      ),
    ),
  );
  // Never settle: the slide auto-advance controller runs for as long as the
  // carousel is on screen.
  await tester.pump();
}

/// The one full-bleed backdrop of the visible slide.
CachedNetworkImage _backdrop(WidgetTester tester) =>
    tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage).first);

Size _backdropBox(WidgetTester tester) =>
    tester.getSize(find.byType(CachedNetworkImage).first);

int _coverWidth(Size box, double dpr) =>
    (math.max(box.width, box.height * 16 / 9) * dpr).round();

void main() {
  setUp(() {
    // The carousel is wrapped in a VisibilityDetector, which otherwise leaves
    // a 500 ms debounce Timer pending past the end of the test.
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  tearDown(() {
    VisibilityDetectorController.instance.updateInterval = const Duration(
      milliseconds: 500,
    );
  });

  group('ExploreCarousel bounds its backdrop decode', () {
    testWidgets('to the slide box at the raster scale, not at the density the '
        'television clamp reports', (tester) async {
      await _pumpCarousel(
        tester,
        physicalSize: _tvPhysicalSize,
        devicePixelRatio: _tvDevicePixelRatio,
        clampDensity: true,
      );

      final box = _backdropBox(tester);
      // The wide layout pads the carousel, so this is not the window width.
      expect(box.width, lessThan(_tvPhysicalSize.width / _tvDevicePixelRatio));

      expect(
        _backdrop(tester).memCacheWidth,
        _coverWidth(box, _tvDevicePixelRatio),
      );
      expect(
        _backdrop(tester).memCacheWidth,
        isNot(_coverWidth(box, 1.0)),
        reason: 'decoded at the clamped MediaQuery DPR, not the raster scale',
      );
    });

    testWidgets('to the width cover actually samples on a tall phone slide', (
      tester,
    ) async {
      await _pumpCarousel(
        tester,
        physicalSize: _phonePhysicalSize,
        devicePixelRatio: _phoneDevicePixelRatio,
      );

      final box = _backdropBox(tester);
      expect(box.height, greaterThan(box.width * 9 / 16));

      expect(
        _backdrop(tester).memCacheWidth,
        _coverWidth(box, _phoneDevicePixelRatio),
      );
      // A bound taken from the box width alone would be soft here: cover
      // scales a 16:9 backdrop up until it fills the height and crops the
      // sides, so the sharp width is the height's, not the box's.
      expect(
        _backdrop(tester).memCacheWidth,
        greaterThan((box.width * _phoneDevicePixelRatio).round()),
      );
    });
  });
}
