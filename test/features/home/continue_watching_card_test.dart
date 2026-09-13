import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/storage/history_repository.dart';
import 'package:skystream/features/home/presentation/widgets/continue_watching_card.dart';
import 'package:skystream/shared/widgets/cards_wrapper.dart';

/// The two footprints the rail actually hands the card
/// (continue_watching_section.dart: 360x200 on tablet/TV, 280x150 on phone).
const Size _tvCard = Size(360, 200);
const Size _phoneCard = Size(280, 150);

/// A 1080p television as Flutter sees it.
const Size _tvScreen = Size(960, 540);
const Size _phoneScreen = Size(412, 915);

HistoryItem _episodeHistory({int position = 15 * 60 * 1000}) {
  return HistoryItem(
    item: MultimediaItem(
      title: 'Test Show',
      url: 'https://example.test/show',
      // Empty poster/banner keeps CachedNetworkImage out of the tree — the
      // card only builds one when AppImageFallbacks returns a non-null URL.
      posterUrl: '',
      contentType: MultimediaContentType.series,
    ),
    position: position,
    duration: 60 * 60 * 1000,
    season: 2,
    episode: 5,
    // Long enough to wrap to the two lines the label is allowed, which is the
    // case that decides how tall the info block is.
    episodeTitle: 'The One Where They All Find Out At Last',
    timestamp: 0,
  );
}

Future<void> _pumpCard(
  WidgetTester tester, {
  required Size card,
  required Size screen,
  HistoryItem? history,
}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = screen * 2;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              // Tight both ways, the way a horizontal rail of fixed height
              // and fixed itemExtent constrains its children. A loose box
              // would let the card pick its own size and hide any geometry
              // bug this file is meant to catch.
              width: card.width,
              height: card.height,
              child: ContinueWatchingCard(
                historyItem: history ?? _episodeHistory(),
                width: card.width,
                isLarge: card == _tvCard,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The alpha of the full-card wash, read off the box that actually paints it
/// rather than off the widget's target value, so a half-finished animation
/// cannot be mistaken for a settled one.
double _washAlpha(WidgetTester tester) {
  // AnimatedContainer folds `color:` into a BoxDecoration, so the wash lands
  // on a DecoratedBox rather than a ColoredBox.
  final DecoratedBox box = tester.widget<DecoratedBox>(
    find.descendant(
      of: find.byType(AnimatedContainer),
      matching: find.byType(DecoratedBox),
    ),
  );
  return (box.decoration as BoxDecoration).color!.a;
}

Finder get _scrim => find.byWidgetPredicate(
  (widget) =>
      widget is Container &&
      widget.decoration is BoxDecoration &&
      (widget.decoration! as BoxDecoration).gradient != null,
);

void main() {
  group('Continue Watching card — attention reveals the artwork', () {
    testWidgets('hover lifts the wash instead of deepening it', (tester) async {
      await _pumpCard(tester, card: _phoneCard, screen: _phoneScreen);

      final double atRest = _washAlpha(tester);
      expect(atRest, closeTo(0.20, 0.001));

      final TestGesture pointer = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await pointer.addPointer(location: Offset.zero);
      addTearDown(pointer.removePointer);
      await pointer.moveTo(tester.getCenter(find.byType(ContinueWatchingCard)));
      await tester.pumpAndSettle();

      final double hovered = _washAlpha(tester);
      expect(
        hovered,
        lessThan(atRest),
        reason:
            'pointing at the card must reveal the artwork, not bury it — '
            'the wash has to get lighter, never heavier',
      );
      expect(hovered, closeTo(0.05, 0.001));

      await pointer.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(_washAlpha(tester), closeTo(0.20, 0.001));
    });

    testWidgets('D-pad focus lifts the wash and adds no second focus stop', (
      tester,
    ) async {
      await _pumpCard(tester, card: _tvCard, screen: _tvScreen);

      final Finder focusInsideCard = find.descendant(
        of: find.byType(CardsWrapper),
        matching: find.byType(Focus),
      );
      expect(
        focusInsideCard,
        findsOneWidget,
        reason:
            'the card must read focus from CardsWrapper.onFocusChange; a '
            'nested Focus node would put a second D-pad stop on every card '
            'in the rail',
      );

      expect(_washAlpha(tester), closeTo(0.20, 0.001));

      final FocusNode node = tester.widget<Focus>(focusInsideCard).focusNode!;
      node.requestFocus();
      await tester.pumpAndSettle();

      expect(
        _washAlpha(tester),
        closeTo(0.05, 0.001),
        reason:
            'the focused card is the one the viewer is reading; it has '
            'to be the brightest thing in the rail, not the dimmest',
      );

      node.unfocus();
      await tester.pumpAndSettle();
      expect(_washAlpha(tester), closeTo(0.20, 0.001));
    });
  });

  group('Continue Watching card — the resume gauge', () {
    testWidgets('paints a track across the unwatched remainder', (
      tester,
    ) async {
      await _pumpCard(
        tester,
        card: _tvCard,
        screen: _tvScreen,
        // 25% of the way in: the fill covers a quarter, so three quarters of
        // the bar has to carry the track or the gauge reads as a stray sliver.
        history: _episodeHistory(position: 15 * 60 * 1000),
      );

      final LinearProgressIndicator bar = tester
          .widget<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          );
      expect(bar.value, closeTo(0.25, 0.001));

      final Color track = bar.backgroundColor!;
      expect(
        track.a,
        greaterThan(0),
        reason: 'a transparent track is not a track',
      );
      expect(
        track.a,
        lessThan(1.0),
        reason: 'the track must stay clearly darker than the white fill',
      );

      // What is actually on the canvas: a full-width track rect first, then
      // the fill rect over the watched quarter only. 4 dp tall, flush to the
      // bottom edge, and the same 360 dp the card is wide.
      final Rect barRect = tester.getRect(find.byType(LinearProgressIndicator));
      expect(barRect.height, 4);
      expect(barRect.width, _tvCard.width);
      expect(
        barRect.bottom,
        tester.getRect(find.byType(ContinueWatchingCard)).bottom,
      );

      expect(
        find.byType(LinearProgressIndicator),
        paints
          ..rect(rect: const Rect.fromLTRB(0, 0, 360, 4), color: track)
          ..rect(rect: const Rect.fromLTRB(0, 0, 90, 4), color: Colors.white),
      );
    });

    testWidgets('the track survives the reveal unchanged', (tester) async {
      await _pumpCard(tester, card: _tvCard, screen: _tvScreen);
      final Color? unfocused = tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .backgroundColor;

      tester
          .widget<Focus>(
            find.descendant(
              of: find.byType(CardsWrapper),
              matching: find.byType(Focus),
            ),
          )
          .focusNode!
          .requestFocus();
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .backgroundColor,
        unfocused,
        reason:
            'the wash is painted under the gauge, so lifting it must not '
            'move the one element on the card that has to stay a gauge',
      );
    });
  });

  group('Continue Watching card — the scrim carries the text', () {
    for (final (String label, Size card, Size screen) in <(String, Size, Size)>[
      ('television', _tvCard, _tvScreen),
      ('phone', _phoneCard, _phoneScreen),
    ]) {
      testWidgets('the scrim covers the whole info block on $label', (
        tester,
      ) async {
        await _pumpCard(tester, card: card, screen: screen);

        final Rect scrim = tester.getRect(_scrim);
        final Rect showTitle = tester.getRect(find.text('Test Show'));
        final Rect cardRect = tester.getRect(find.byType(ContinueWatchingCard));

        expect(
          scrim.top,
          lessThanOrEqualTo(showTitle.top),
          reason:
              'the topmost line of the info block must sit inside the '
              'gradient. Now that focus LIGHTENS the field wash, the wash is '
              'no longer holding this text up — the scrim is.',
        );
        expect(scrim.bottom, cardRect.bottom);
        expect(scrim.width, cardRect.width);

        // And the label really is two lines here, which is the case that
        // makes the block taller than a fixed-height band.
        expect(
          tester.getRect(find.textContaining('S2 E5')).height,
          greaterThan(20),
        );
      });
    }
  });
}
