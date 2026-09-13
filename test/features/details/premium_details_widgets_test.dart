/// The "More Like This" rail sizes itself off the window, not off a device.
///
/// It used to read `context.isDesktop || context.isTv`, and the second half of
/// that OR was the input-model getter: it answered
/// [MediaQueryData.navigationMode], which no host in this app declares. So it
/// was false on the television it was named for - a television gets the large
/// rail from its 960 dp width, through `isDesktop`, like any other big window
/// - and the only surface it could ever have promoted was one that declares
/// directional navigation while sitting under the 900 dp desktop breakpoint.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/details/presentation/widgets/premium_details_widgets.dart';

MultimediaItem _item(int i) =>
    MultimediaItem(title: 'Title $i', url: 'https://x.test/$i', posterUrl: '');

/// Pumps the rail at a real window size, with real (tight) constraints: the
/// rail is a child of the details page's scroll view, which hands it the full
/// window width and lets it choose its own height.
Future<void> _pumpRail(
  WidgetTester tester, {
  required Size window,
  NavigationMode navigationMode = NavigationMode.traditional,
}) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(navigationMode: navigationMode),
          child: Scaffold(
            body: SingleChildScrollView(
              child: RecommendationsCarousel(
                items: <MultimediaItem>[for (int i = 0; i < 4; i++) _item(i)],
                onItemTap: (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The rail's own height, which is the cheapest read-out of the size verdict:
/// 310 large, 180 small.
double _railHeight(WidgetTester tester) =>
    tester.getSize(find.byType(ListView)).height;

Finder _cardsOfWidth(double width) => find.byWidgetPredicate(
  (Widget w) => w is SizedBox && w.width == width && w.height == null,
);

void main() {
  testWidgets('a 960x540 dp television gets the large rail on width alone', (
    WidgetTester tester,
  ) async {
    await _pumpRail(tester, window: const Size(960, 540));

    expect(_railHeight(tester), 310);
    expect(_cardsOfWidth(180), findsWidgets);
  });

  testWidgets('an 800 dp window gets the small rail', (
    WidgetTester tester,
  ) async {
    await _pumpRail(tester, window: const Size(800, 900));

    expect(_railHeight(tester), 180);
    expect(_cardsOfWidth(110), findsWidgets);
  });

  testWidgets('declaring directional navigation does not resize the rail', (
    WidgetTester tester,
  ) async {
    // A remote, a keyboard or a paired gamepad changes how focus moves. It
    // does not change how wide the window is, so it must not change a layout
    // that is about how much fits on a row.
    await _pumpRail(
      tester,
      window: const Size(800, 900),
      navigationMode: NavigationMode.directional,
    );

    expect(_railHeight(tester), 180);
    expect(_cardsOfWidth(110), findsWidgets);
    expect(_cardsOfWidth(180), findsNothing);
  });
}
