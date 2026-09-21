import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/explore/presentation/delegates/explore_search_delegate.dart';
import 'package:skystream/features/home/presentation/delegates/home_search_delegate.dart';
import 'package:skystream/features/search/data/search_history_store.dart';
import 'package:skystream/features/search/presentation/search_provider.dart';
import 'package:skystream/features/search/presentation/search_screen.dart';
import 'package:skystream/features/search/presentation/widgets/search_suggestion_row.dart';
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
  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  /// The text of the row that currently holds focus, or null.
  String? focusedRowText(WidgetTester tester) {
    final focused = tester
        .widgetList<SearchSuggestionRow>(find.byType(SearchSuggestionRow))
        .where((row) => row.focusNode?.hasFocus ?? false);
    return focused.isEmpty ? null : focused.first.text;
  }

  bool fieldHasFocus(WidgetTester tester) {
    return tester
        .widgetList<EditableText>(find.byType(EditableText))
        .any((field) => field.focusNode.hasFocus);
  }

  group('search tab', () {
    Future<void> pumpSearch(
      WidgetTester tester, {
      required List<String> history,
      required Size size,
    }) async {
      tester.view.physicalSize = size;
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
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
    }

    // The bar used to be a column, so down from the field meant "into the
    // scope pill". The pill stands beside the field now and the panel is what
    // is underneath, so down has to reach the list.
    for (final (name, size) in [
      ('desktop', const Size(1440, 900)),
      ('phone', const Size(400, 800)),
    ]) {
      testWidgets('$name: down from the field enters the list', (tester) async {
        await pumpSearch(tester, history: ['Dune', 'Arrival'], size: size);

        await press(tester, LogicalKeyboardKey.arrowDown);

        expect(focusedRowText(tester), 'Dune');
      });

      testWidgets('$name: up from the first row returns to the field', (
        tester,
      ) async {
        await pumpSearch(tester, history: ['Dune'], size: size);

        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focusedRowText(tester), 'Dune');

        await press(tester, LogicalKeyboardKey.arrowUp);

        expect(fieldHasFocus(tester), isTrue);
      });

      testWidgets('$name: right off a row reaches its remove button', (
        tester,
      ) async {
        await pumpSearch(tester, history: ['Dune'], size: size);

        await press(tester, LogicalKeyboardKey.arrowDown);
        await press(tester, LogicalKeyboardKey.arrowRight);

        // The body node gave the button its focus, so neither the row body
        // nor the field holds it now.
        expect(focusedRowText(tester), isNull);
        expect(fieldHasFocus(tester), isFalse);

        // And select on it drops the recent.
        await press(tester, LogicalKeyboardKey.enter);
        expect(find.text('Dune'), findsNothing);
      });

      testWidgets('$name: select on a row runs that search', (tester) async {
        await pumpSearch(tester, history: ['Dune'], size: size);

        await press(tester, LogicalKeyboardKey.arrowDown);
        await press(tester, LogicalKeyboardKey.enter);

        // The panel is down and the query is committed to the field. It used
        // to reopen a frame later: tearing down the focused row bounced focus
        // back to the field, which the screen reads as "show the panel".
        expect(find.byType(SearchSuggestionRow), findsNothing);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller?.text,
          'Dune',
        );
      });
    }
  });

  group('delegates', () {
    Future<void> openSearch(
      WidgetTester tester,
      SearchDelegate<void> Function() delegate, {
      required List<String> history,
    }) async {
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            searchHistoryStoreProvider.overrideWithValue(
              _FakeStore(List<String>.from(history)),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData.dark(),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => showSearch<void>(
                      context: context,
                      delegate: delegate(),
                    ),
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

    // An EditableText swallows arrow keys for its own caret, so without the
    // global handler a remote could never leave the search field.
    testWidgets('home: down from the field enters the list', (tester) async {
      await openSearch(
        tester,
        HomeSearchDelegate.new,
        history: ['Dune', 'Arrival'],
      );
      expect(fieldHasFocus(tester), isTrue);

      await press(tester, LogicalKeyboardKey.arrowDown);

      expect(focusedRowText(tester), 'Dune');
    });

    testWidgets('home: right off a row reaches its remove button', (
      tester,
    ) async {
      await openSearch(tester, HomeSearchDelegate.new, history: ['Dune']);

      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.enter);

      expect(find.text('Dune'), findsNothing);
    });

    testWidgets('explore: down from the field enters the list', (tester) async {
      await openSearch(
        tester,
        ExploreSearchDelegate.new,
        history: ['Dune', 'Arrival'],
      );
      expect(fieldHasFocus(tester), isTrue);

      await press(tester, LogicalKeyboardKey.arrowDown);

      expect(focusedRowText(tester), 'Dune');
    });

    testWidgets('explore: select on a row runs that search', (tester) async {
      await openSearch(tester, ExploreSearchDelegate.new, history: ['Dune']);

      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.enter);

      // showResults swapped the suggestions out for the results grid.
      expect(find.byType(SearchSuggestionRow), findsNothing);
    });
  });
}
