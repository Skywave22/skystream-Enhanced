import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/shared/widgets/tv_logical_scale.dart';

/// A television reports about 960 dp of width whatever its panel is, so the
/// same layout that breathes on a laptop is drawn at twice the relative size
/// on a set. This hands the tree more logical pixels and scales the result
/// back up to fill the screen.
///
/// What this replaces was `MediaQuery(devicePixelRatio: 1.0)`, which reads
/// like it clamps the density and does nothing of the sort: layout is in
/// logical pixels and that field is one widgets read, not one that resizes
/// anything. The first test here is the one that would have caught it.
void main() {
  /// The logical size the subtree is handed, and the box it fills.
  ({Size size, Rect rect}) measure(WidgetTester tester) => (
    size: MediaQuery.sizeOf(tester.element(find.byKey(const Key('body')))),
    rect: tester.getRect(find.byKey(const Key('body'))),
  );

  Future<void> pump(
    WidgetTester tester, {
    required Size panel,
    required bool enabled,
    double logicalWidth = kTvLogicalWidth,
  }) async {
    tester.view.physicalSize = panel;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: TvLogicalScale(
          enabled: enabled,
          logicalWidth: logicalWidth,
          child: const SizedBox.expand(
            child: ColoredBox(color: Color(0xFF000000), key: Key('body')),
          ),
        ),
      ),
    );
  }

  testWidgets('a television is handed the logical width it asks for', (
    tester,
  ) async {
    // 1920 dp of panel, laid out as 1280: a third more room than the set
    // reports, which is the whole point.
    await pump(tester, panel: const Size(1920, 1080), enabled: true);

    final measured = measure(tester);
    expect(measured.size.width, kTvLogicalWidth);
    expect(
      measured.size.height,
      1080 / (1920 / kTvLogicalWidth),
      reason: 'the aspect ratio is the panel\'s; only the scale changed',
    );
  });

  testWidgets('and every physical pixel is still covered', (tester) async {
    // The other half of the contract: more room to lay out in must not mean
    // a letterbox. The subtree is scaled back up to fill the panel.
    await pump(tester, panel: const Size(1920, 1080), enabled: true);

    expect(measure(tester).rect, const Rect.fromLTWH(0, 0, 1920, 1080));
  });

  testWidgets('a pointer lands where it looks like it landed', (tester) async {
    // A Transform that did not carry its hit testing would be worse than the
    // problem it solves: every tap and every D-pad focus rect would be out by
    // the scale factor.
    Offset? tapped;
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: TvLogicalScale(
          enabled: true,
          child: Builder(
            builder: (context) => GestureDetector(
              onTapDown: (d) => tapped = d.localPosition,
              child: const SizedBox.expand(
                child: ColoredBox(color: Color(0xFF000000)),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tapAt(const Offset(960, 540));
    await tester.pump();

    // Half the panel is half the logical box, whatever the scale between them.
    expect(tapped!.dx, closeTo(kTvLogicalWidth / 2, 0.5));
  });

  testWidgets('every inset travels with the size', (tester) async {
    // A safe-area padding left at the panel's scale would reserve three times
    // the band it means once the subtree is scaled back up.
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(
          size: Size(1920, 1080),
          padding: EdgeInsets.only(top: 48),
          viewPadding: EdgeInsets.only(top: 48),
        ),
        child: MaterialApp(
          home: TvLogicalScale(
            enabled: true,
            child: SizedBox.expand(
              child: ColoredBox(color: Color(0xFF000000), key: Key('body')),
            ),
          ),
        ),
      ),
    );

    const scale = 1920 / kTvLogicalWidth;
    expect(
      MediaQuery.paddingOf(tester.element(find.byKey(const Key('body')))).top,
      closeTo(48 / scale, 0.01),
    );
  });

  testWidgets('a device that is not a television is untouched', (tester) async {
    await pump(tester, panel: const Size(1920, 1080), enabled: false);

    final measured = measure(tester);
    expect(measured.size.width, 1920, reason: 'no MediaQuery of its own');
    expect(find.byType(FittedBox), findsNothing);
  });

  testWidgets('a panel narrower than the target is left alone', (tester) async {
    // Scaling *down* would make a small screen worse to satisfy a rule
    // written for large ones.
    await pump(tester, panel: const Size(1024, 600), enabled: true);

    expect(measure(tester).size.width, 1024);
  });

  testWidgets('a zero-width view does not divide by it', (tester) async {
    // One frame on some embedders, and an infinite canvas if taken at face
    // value.
    await pump(tester, panel: const Size(0, 0), enabled: true);

    expect(tester.takeException(), isNull);
  });
}
