import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/search/data/search_history_store.dart';
import 'package:skystream/features/search/presentation/search_provider.dart';
import 'package:skystream/features/search/presentation/search_screen.dart';
import 'package:skystream/features/search/presentation/widgets/search_header_bar.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

class _FakeStore implements SearchHistoryStore {
  List<String> queries;

  _FakeStore(this.queries);

  @override
  List<String> read() => queries;

  @override
  Future<void> write(List<String> next) async {
    queries = List<String>.from(next);
  }
}

void main() {
  /// The search tab past the 600 dp tablet breakpoint - the desktop and
  /// television layout.
  Future<void> pumpDesktopSearch(
    WidgetTester tester, {
    List<String> history = const [],
  }) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          searchHistoryStoreProvider.overrideWithValue(
            _FakeStore(List<String>.from(history)),
          ),
          searchResultsProvider.overrideWith(
            (ref) => Stream.value(const SearchAggregateState()),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.dark(),
          home: const SearchScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder flyout() => find.byKey(const ValueKey('searchFlyout'));

  /// The bordered pill the field sits in - which is what the scope pill
  /// matches and what the flyout anchors to. The `TextField`'s own rect is
  /// inset from it by the 1.2 dp border, so measuring that instead reports
  /// a field 2.4 dp shorter and 2.4 dp narrower than the one on screen.
  Finder fieldPill() => find
      .ancestor(of: find.byType(TextField), matching: find.byType(Container))
      .first;

  group('desktop search chrome', () {
    // The screen used to paint a 2000x1125 backdrop photograph under four
    // blending gradients and a focus spotlight, all of it behind a text
    // field and a list of titles.
    testWidgets('paints no backdrop image', (tester) async {
      await pumpDesktopSearch(tester);

      expect(find.byType(Image), findsNothing);
    });

    testWidgets('settles, because nothing on it loops', (tester) async {
      await pumpDesktopSearch(tester);

      // The live-TV equalizer used to repeat() forever, which meant this
      // layout could never reach a settled frame.
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('stands the scope pill beside the field, not below it', (
      tester,
    ) async {
      await pumpDesktopSearch(tester);

      final field = tester.getRect(fieldPill());
      final pill = tester.getRect(find.byType(SearchScopeSwitcher));

      expect(
        pill.left,
        greaterThan(field.right),
        reason: 'the pill belongs to the right of the field',
      );
      expect(
        pill.height,
        field.height,
        reason: 'beside the field means at the field\'s height',
      );
      expect(
        pill.center.dy,
        moreOrLessEquals(field.center.dy, epsilon: 1),
        reason: 'and on the same centre line',
      );
    });
  });

  group('desktop search flyout', () {
    testWidgets('stays closed until the field is focused', (tester) async {
      await pumpDesktopSearch(tester, history: ['Dune']);

      expect(flyout(), findsNothing);
    });

    testWidgets('opens under the field at the field\'s width', (tester) async {
      await pumpDesktopSearch(tester, history: ['Dune', 'Arrival']);

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();

      expect(flyout(), findsOneWidget);
      final field = tester.getRect(fieldPill());
      final panel = tester.getRect(flyout());

      expect(panel.top, greaterThan(field.bottom));
      expect(panel.left, moreOrLessEquals(field.left, epsilon: 1));
      expect(panel.width, moreOrLessEquals(field.width, epsilon: 1));
    });

    testWidgets('wraps to its rows rather than filling the window', (
      tester,
    ) async {
      await pumpDesktopSearch(tester, history: ['Dune', 'Arrival']);

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();

      // Two rows is a small flyout; the ceiling is 420 and the window 900.
      expect(
        tester.getRect(flyout()).height,
        lessThan(SearchHeaderBar.kFlyoutMaxHeight),
      );
    });

    testWidgets('holds the recents, and the results stay behind it', (
      tester,
    ) async {
      await pumpDesktopSearch(tester, history: ['Dune']);

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: flyout(), matching: find.text('Dune')),
        findsOneWidget,
      );
      // The panel is a layer over the body now, not a replacement for it -
      // the empty-state prompt is still on the screen underneath.
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(l10n.searchFavoriteContent), findsOneWidget);
    });

    testWidgets('closes on submit', (tester) async {
      await pumpDesktopSearch(tester, history: ['Dune']);

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(flyout(), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Dune');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(flyout(), findsNothing);
    });
  });
}
