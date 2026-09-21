import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/explore/presentation/delegates/explore_search_delegate.dart';
import 'package:skystream/features/home/presentation/delegates/home_search_delegate.dart';
import 'package:skystream/features/search/data/search_history_store.dart';
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

  /// Opens [delegate] over a bare host page.
  ///
  /// The field is left empty throughout: typing two or more characters starts
  /// a real TMDB fetch, and the recents are decided before any of that.
  Future<void> openSearch(
    WidgetTester tester,
    SearchDelegate<void> Function() delegate, {
    required List<String> history,
  }) async {
    store = _FakeStore(List<String>.from(history));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [searchHistoryStoreProvider.overrideWithValue(store)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () =>
                      showSearch<void>(context: context, delegate: delegate()),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  // Both delegates used to return a blank sheet for an empty query, which is
  // exactly the moment the recents are the only thing worth showing.
  group('home search delegate', () {
    testWidgets('shows recents on an empty query', (tester) async {
      await openSearch(
        tester,
        HomeSearchDelegate.new,
        history: ['Dune', 'Arrival'],
      );

      expect(find.text('Dune'), findsOneWidget);
      expect(find.text('Arrival'), findsOneWidget);
      expect(find.byIcon(Icons.history_rounded), findsNWidgets(2));
    });

    testWidgets('removes one recent without touching the rest', (tester) async {
      await openSearch(
        tester,
        HomeSearchDelegate.new,
        history: ['Dune', 'Arrival'],
      );

      await tester.tap(find.byIcon(Icons.close_rounded).first);
      await tester.pumpAndSettle();

      expect(find.text('Dune'), findsNothing);
      expect(find.text('Arrival'), findsOneWidget);
      expect(store.queries, ['Arrival']);
    });

    testWidgets('stays blank when there is no history', (tester) async {
      await openSearch(tester, HomeSearchDelegate.new, history: const []);

      expect(find.byIcon(Icons.history_rounded), findsNothing);
      expect(find.text('No results found'), findsNothing);
    });
  });

  group('explore search delegate', () {
    testWidgets('shows recents on an empty query', (tester) async {
      await openSearch(
        tester,
        ExploreSearchDelegate.new,
        history: ['Dune', 'Arrival'],
      );

      expect(find.text('Dune'), findsOneWidget);
      expect(find.text('Arrival'), findsOneWidget);
      expect(find.byIcon(Icons.history_rounded), findsNWidgets(2));
    });

    testWidgets('removes one recent without touching the rest', (tester) async {
      await openSearch(
        tester,
        ExploreSearchDelegate.new,
        history: ['Dune', 'Arrival'],
      );

      await tester.tap(find.byIcon(Icons.close_rounded).first);
      await tester.pumpAndSettle();

      expect(find.text('Dune'), findsNothing);
      expect(find.text('Arrival'), findsOneWidget);
      expect(store.queries, ['Arrival']);
    });

    testWidgets('stays blank when there is no history', (tester) async {
      await openSearch(tester, ExploreSearchDelegate.new, history: const []);

      expect(find.byIcon(Icons.history_rounded), findsNothing);
      expect(find.text('No results found'), findsNothing);
    });
  });
}
