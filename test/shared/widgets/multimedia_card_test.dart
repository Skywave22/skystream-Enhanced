import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/settings/presentation/general_settings_provider.dart';
import 'package:skystream/shared/widgets/multimedia_card.dart';

/// A 1080p television: 1920x1080 physical, 960x540 logical at a raster scale
/// of 2. This is the device the decode bound exists for — the source is
/// upgraded to `w780` here (tmdb_config.dart), the cards are small, and the
/// image cache is capped at 50 MB in main.dart.
const double _tvDevicePixelRatio = 2.0;
const Size _tvPhysicalSize = Size(1920, 1080);

/// A bookmarks-grid cell (bookmarks_tab.dart, maxCrossAxisExtent 180). The
/// point of these numbers is that they are TIGHT and they are NOT the
/// `cardWidth` the card asks for: on a 960 dp-wide view `context.isDesktop` is
/// true, so the card requests 200 dp and the grid gives it 173.
const Size _cellSize = Size(173, 266);

/// What the card asks for, and would decode at if it trusted its own
/// parameter instead of the constraints it was handed.
const double _requestedCardWidth = 200;

/// Reproduces the television branch of `main.dart`'s MaterialApp.builder,
/// which clamps `MediaQueryData.devicePixelRatio` to 1.0 for the whole app.
///
/// That clamp cannot change the raster scale — that comes off the FlutterView
/// — but it is what `MediaQuery.devicePixelRatioOf` returns, so a decode bound
/// read from MediaQuery asks for half the pixels the panel paints.
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

Future<void> _pumpCard(
  WidgetTester tester, {
  String titlePosition = 'below',
  bool isPortrait = true,
  Size cell = _cellSize,
}) async {
  tester.view.devicePixelRatio = _tvDevicePixelRatio;
  tester.view.physicalSize = _tvPhysicalSize;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        generalSettingsProvider.overrideWithValue(
          GeneralSettings(titlePosition: titlePosition),
        ),
      ],
      child: MaterialApp(
        builder: (context, child) => _TvDensityClamp(child: child!),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: cell.width,
              height: cell.height,
              child: MultimediaCard(
                imageUrl: '',
                title: 'Title',
                heroTag: 'poster_0',
                isPortrait: isPortrait,
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  // Never settle: the poster placeholder shimmers forever.
  await tester.pump();
}

CachedNetworkImage _poster(WidgetTester tester) =>
    tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));

void main() {
  group('MultimediaCard bounds its decode to the box it is painted at', () {
    testWidgets('from the constraints it is given, not the width it asks for', (
      tester,
    ) async {
      // Title inside, so the artwork is Positioned.fill in the cell and its
      // box is exactly the cell: no title row to subtract, nothing to measure.
      await _pumpCard(tester, titlePosition: 'inside');

      expect(tester.getSize(find.byType(CachedNetworkImage)), _cellSize);

      // BoxFit.cover on a 2:3 poster in a 173x266 box is height-driven by a
      // hair, so the decode has to be 266 * 2/3 = 177.33 dp wide, and 2x that
      // in physical pixels.
      const expected = 355; // (266 * 2 / 3 * 2).round()
      expect(_poster(tester).memCacheWidth, expected);

      // The two wrong answers this pins against.
      expect(
        _poster(tester).memCacheWidth,
        isNot((_requestedCardWidth * _tvDevicePixelRatio).round()),
        reason: 'decoded at the requested cardWidth, not the real cell',
      );
      expect(
        _poster(tester).memCacheWidth,
        isNot(178), // (266 * 2 / 3 * 1.0).round(), the clamped MediaQuery
        reason: 'decoded at the clamped MediaQuery DPR, not the raster scale',
      );
    });

    testWidgets('with the title below, where the artwork is shorter than the '
        'cell', (tester) async {
      await _pumpCard(tester);

      final box = tester.getSize(find.byType(CachedNetworkImage));
      expect(box.height, lessThan(_cellSize.height));

      final expected =
          (math.max(box.width, box.height * 2 / 3) * _tvDevicePixelRatio)
              .round();
      expect(_poster(tester).memCacheWidth, expected);
    });

    testWidgets('using the backdrop aspect for a landscape card', (
      tester,
    ) async {
      // A landscape card holds a 16:9 still, so cover is width-driven and the
      // height term must not inflate the bound.
      await _pumpCard(
        tester,
        titlePosition: 'inside',
        isPortrait: false,
        cell: const Size(300, 168),
      );

      expect(
        _poster(tester).memCacheWidth,
        (300 * _tvDevicePixelRatio).round(),
      );
    });
  });
}
