import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/nuvio/data/nuvio_repository.dart';
import 'package:skystream/core/nuvio/models/nuvio_models.dart';
import 'package:skystream/features/nuvio/presentation/nuvio_plugins_view.dart';
import 'package:skystream/shared/widgets/cards_wrapper.dart';

/// The two decoration layers a focused scraper row is supposed to draw around
/// itself: the accent glow (a BoxShadow painted behind it) and the accent ring
/// plus tint (a border and a fill painted behind its text).
///
/// Matched on the recipe's own signature rather than on position in the tree:
/// an AnimatedContainer builds a plain Container, so the repository card
/// itself turns up in this walk. Only the row strokes its border outside the
/// box, and only the row's glow is a single spread-less shadow (the card's
/// carries spreadRadius 1).
({BoxDecoration? glow, BoxDecoration? ring}) _rowLayers(
  WidgetTester tester,
  Finder rowTitle,
) {
  BoxDecoration? ring;
  BoxDecoration? glow;
  for (final container in tester.widgetList<Container>(
    find.ancestor(of: rowTitle, matching: find.byType(Container)),
  )) {
    final decoration = container.decoration;
    if (decoration is! BoxDecoration) continue;
    final border = decoration.border;
    if (border is Border &&
        border.top.strokeAlign == BorderSide.strokeAlignOutside) {
      ring ??= decoration;
    }
    final shadow = decoration.boxShadow;
    if (shadow != null &&
        shadow.length == 1 &&
        shadow.single.spreadRadius == 0) {
      glow ??= decoration;
    }
  }
  return (glow: glow, ring: ring);
}

/// The repository card that encloses [inner].
BoxDecoration _cardDecoration(
  WidgetTester tester,
  Finder inner,
  Color surface,
) {
  final cards = tester
      .widgetList<AnimatedContainer>(
        find.ancestor(of: inner, matching: find.byType(AnimatedContainer)),
      )
      .map((c) => c.decoration)
      .whereType<BoxDecoration>()
      .where((d) => d.color == surface)
      .toList();
  expect(
    cards,
    hasLength(1),
    reason: 'expected exactly one _FocusableCard above $inner',
  );
  return cards.single;
}

/// Moves real focus onto the control [finder] points at, the way a D-pad
/// would, by asking for the nearest enclosing focus node.
Future<void> _focusOn(WidgetTester tester, Finder finder) async {
  final node = Focus.maybeOf(tester.element(finder), createDependency: false);
  expect(node, isNotNull, reason: 'nothing focusable at $finder');
  node!.requestFocus();
  // Two frames: FocusManager applies the change in a microtask, so the first
  // pump is what delivers onFocusChange and the second is what paints it.
  await tester.pump();
  await tester.pump();
}

NuvioState _twoScrapers() {
  const scrapers = [
    NuvioScraperInfo(
      id: 'a',
      name: 'Scraper A',
      version: '1.0.0',
      filename: 'a.js',
    ),
    NuvioScraperInfo(
      id: 'b',
      name: 'Scraper B',
      version: '1.0.0',
      filename: 'b.js',
    ),
  ];
  return NuvioState(
    isLoading: false,
    repos: [
      NuvioRepo(
        manifestUrl: 'https://example.com/manifest.json',
        addedAt: DateTime.utc(2026, 1, 1),
        manifest: const NuvioManifest(
          name: 'Test Repo',
          version: '2.0.0',
          scrapers: scrapers,
        ),
      ),
    ],
  );
}

Widget _app(NuvioState state) => ProviderScope(
  overrides: [nuvioRepositoryProvider.overrideWithValue(state)],
  child: const MaterialApp(home: Scaffold(body: NuvioPluginsView())),
);

void main() {
  group('scraper row focus affordance', () {
    setUp(() {
      // A television-sized surface: every scraper row is laid out, so the
      // assertions are about what is drawn and not about what got built.
      final view = TestWidgetsFlutterBinding.ensureInitialized()
          .platformDispatcher
          .views
          .first;
      view.physicalSize = const Size(1280, 2400);
      view.devicePixelRatio = 1.0;
      addTearDown(view.reset);
    });

    testWidgets(
      'focusing one scraper row rings that row and leaves its neighbour plain',
      (WidgetTester tester) async {
        await tester.pumpWidget(_app(_twoScrapers()));
        await tester.pumpAndSettle();

        final primary = Theme.of(
          tester.element(find.text('Scraper A')),
        ).colorScheme.primary;

        expect(_rowLayers(tester, find.text('Scraper A')).ring, isNull);
        expect(_rowLayers(tester, find.text('Scraper B')).ring, isNull);

        final rowB = find.ancestor(
          of: find.text('Scraper B'),
          matching: find.byType(ListTile),
        );
        await _focusOn(
          tester,
          find.descendant(
            of: rowB,
            matching: find.byIcon(Icons.play_circle_outline_rounded),
          ),
        );

        final focused = _rowLayers(tester, find.text('Scraper B'));

        final ring = focused.ring;
        expect(ring, isNotNull, reason: 'focused row drew no ring');
        final side = (ring!.border! as Border).top;
        expect(side.color, primary);
        expect(side.width, CardFocusAffordance.ringWidth);
        expect(side.strokeAlign, BorderSide.strokeAlignOutside);
        expect(
          ring.color,
          primary.withValues(alpha: CardFocusAffordance.tintOpacity),
        );

        final glow = focused.glow;
        expect(glow, isNotNull, reason: 'focused row drew no glow');
        expect(
          glow!.boxShadow!.single.blurRadius,
          CardFocusAffordance.glowBlurRadius,
        );
        expect(
          glow.boxShadow!.single.color,
          primary.withValues(alpha: CardFocusAffordance.glowOpacity),
        );

        // The neighbour is untouched — this is the whole complaint: from three
        // metres you must be able to tell the fifth row from the fourth.
        expect(_rowLayers(tester, find.text('Scraper A')).ring, isNull);
        expect(_rowLayers(tester, find.text('Scraper A')).glow, isNull);
      },
    );

    testWidgets(
      'the repository card still lights for its own header, then hands over',
      (WidgetTester tester) async {
        await tester.pumpWidget(_app(_twoScrapers()));
        await tester.pumpAndSettle();

        final theme = Theme.of(tester.element(find.text('Test Repo')));
        final surface = theme.colorScheme.surface;
        final primary = theme.colorScheme.primary;

        // The header belongs to the card, so the card is what lights up.
        await _focusOn(tester, find.text('Test Repo'));
        var card = _cardDecoration(tester, find.text('Test Repo'), surface);
        expect((card.border! as Border).top.color, primary);
        expect((card.border! as Border).top.width, 2.0);
        expect(card.boxShadow, isNotNull);

        // Walk down onto a row and the card must hand the affordance over,
        // instead of glowing around all of the scrapers at once.
        final rowB = find.ancestor(
          of: find.text('Scraper B'),
          matching: find.byType(ListTile),
        );
        await _focusOn(
          tester,
          find.descendant(
            of: rowB,
            matching: find.byIcon(Icons.play_circle_outline_rounded),
          ),
        );

        card = _cardDecoration(tester, find.text('Scraper B'), surface);
        expect(
          card.boxShadow,
          isNull,
          reason: 'the repository card kept glowing for a row inside it',
        );
        expect((card.border! as Border).top.width, 1.0);
        expect(_rowLayers(tester, find.text('Scraper B')).ring, isNotNull);

        // And back up to the header: the card takes it back.
        await _focusOn(tester, find.text('Test Repo'));
        card = _cardDecoration(tester, find.text('Test Repo'), surface);
        expect(
          card.boxShadow,
          isNotNull,
          reason: 'the card never recovered after a row had the focus',
        );
        expect(_rowLayers(tester, find.text('Scraper B')).ring, isNull);
      },
    );
  });
}
