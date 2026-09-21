import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/search/data/search_history_store.dart';
import 'package:skystream/features/search/presentation/search_history_provider.dart';
import 'package:skystream/features/search/presentation/search_provider.dart';
import 'package:skystream/features/search/presentation/search_screen.dart';
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
  late _FakeStore store;

  /// The search tab, with the provider search itself stubbed out.
  ///
  /// [searchResultsProvider] reaches for the extension manager and fans out
  /// to every installed provider; the recents are decided long before any of
  /// that, so it is replaced with a settled empty result.
  ///
  /// Pumped at phone width on purpose. Past the 600 dp tablet breakpoint the
  /// screen swaps in the scope pill, whose live-TV equalizer animates on a
  /// repeating controller - `pumpAndSettle` would never return.
  Future<ProviderContainer> pumpSearchScreen(
    WidgetTester tester, {
    required List<String> history,
  }) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    store = _FakeStore(List<String>.from(history));

    final container = ProviderContainer(
      overrides: [
        searchHistoryStoreProvider.overrideWithValue(store),
        searchResultsProvider.overrideWith(
          (ref) => Stream.value(const SearchAggregateState()),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          // Light theme: the dark one paints a backdrop photo the test has no
          // asset bundle for.
          theme: ThemeData.light(),
          home: const SearchScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> focusSearchField(WidgetTester tester) async {
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
  }

  group('search tab recents', () {
    testWidgets('stay hidden until the field is focused', (tester) async {
      await pumpSearchScreen(tester, history: ['Dune']);

      expect(find.text('Dune'), findsNothing);
    });

    testWidgets('appear on an empty focused field', (tester) async {
      await pumpSearchScreen(tester, history: ['Dune', 'Arrival']);

      await focusSearchField(tester);

      expect(find.text('Dune'), findsOneWidget);
      expect(find.text('Arrival'), findsOneWidget);
      expect(find.byIcon(Icons.history_rounded), findsNWidgets(2));
    });

    testWidgets('leave the prompt in place when there is no history', (
      tester,
    ) async {
      await pumpSearchScreen(tester, history: const []);

      await focusSearchField(tester);

      expect(find.byIcon(Icons.history_rounded), findsNothing);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(l10n.searchFavoriteContent), findsOneWidget);
    });

    testWidgets('narrow to what the user is typing', (tester) async {
      await pumpSearchScreen(tester, history: ['Mad Max', 'Batman', 'Arrival']);
      await focusSearchField(tester);

      await tester.enterText(find.byType(TextField), 'ma');
      await tester.pumpAndSettle();

      expect(find.text('Mad Max'), findsOneWidget);
      expect(find.text('Batman'), findsOneWidget);
      expect(find.text('Arrival'), findsNothing);
    });

    testWidgets('drop a single entry from the panel and from the store', (
      tester,
    ) async {
      await pumpSearchScreen(tester, history: ['Dune', 'Arrival']);
      await focusSearchField(tester);

      await tester.tap(find.byIcon(Icons.close_rounded).first);
      await tester.pumpAndSettle();

      expect(find.text('Dune'), findsNothing);
      expect(find.text('Arrival'), findsOneWidget);
      expect(store.queries, ['Arrival']);
    });

    testWidgets('record the query and close the panel on submit', (
      tester,
    ) async {
      final container = await pumpSearchScreen(tester, history: const []);
      await focusSearchField(tester);

      await tester.enterText(find.byType(TextField), 'Dune');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(container.read(searchHistoryProvider), ['Dune']);
      expect(store.queries, ['Dune']);
      // Submitted, so the panel is down and the results view is showing -
      // the recent must not be sitting on top of it.
      expect(find.byIcon(Icons.history_rounded), findsNothing);
    });

    testWidgets('come back when the user returns to a committed query', (
      tester,
    ) async {
      await pumpSearchScreen(tester, history: ['Dune Part Two']);
      await focusSearchField(tester);

      await tester.enterText(find.byType(TextField), 'Dune');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.history_rounded), findsNothing);

      await focusSearchField(tester);

      // "Dune" is now the newest entry and "Dune Part Two" still matches it.
      expect(find.byIcon(Icons.history_rounded), findsNWidgets(2));
    });
  });
}
