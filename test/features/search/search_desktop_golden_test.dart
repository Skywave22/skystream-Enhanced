@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/search/data/search_history_store.dart';
import 'package:skystream/features/search/presentation/search_provider.dart';
import 'package:skystream/features/home/presentation/delegates/home_search_delegate.dart';
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

/// Pictures of the desktop search chrome, for reviewing the layout by eye.
///
/// Tagged `golden` and excluded from the default run (see dart_test.yaml):
/// these are a drawing tool, not a regression gate - text renders in the test
/// font, so a pixel diff here would fail for reasons that have nothing to do
/// with the layout. Draw them with:
///
///     flutter test --tags golden --update-goldens
void main() {
  Future<void> pump(
    WidgetTester tester, {
    List<String> history = const [],
    Size size = const Size(1280, 560),
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
  }

  testWidgets('resting', (tester) async {
    await pump(tester);
    await expectLater(
      find.byType(SearchScreen),
      matchesGoldenFile('goldens/search_desktop_resting.png'),
    );
  });

  testWidgets('phone, panel open', (tester) async {
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pump(
      tester,
      history: ['Dune Part Two', 'Arrival', 'The Bear'],
      size: const Size(390, 700),
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/search_phone_panel.png'),
    );
  });

  // The highlight is the point of these two: a resting golden cannot show
  // whether the row reads as "pointed at" or as "text selected".
  testWidgets('phone, first row focused', (tester) async {
    await pump(
      tester,
      history: ['Dune Part Two', 'Arrival', 'The Bear'],
      size: const Size(390, 420),
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/search_phone_row_focused.png'),
    );
  });

  testWidgets('phone, remove button focused', (tester) async {
    await pump(
      tester,
      history: ['Dune Part Two', 'Arrival', 'The Bear'],
      size: const Size(390, 420),
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/search_phone_button_focused.png'),
    );
  });

  testWidgets('home delegate, recents', (tester) async {
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          searchHistoryStoreProvider.overrideWithValue(
            _FakeStore(['Dune Part Two', 'Arrival', 'The Bear']),
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
                    delegate: HomeSearchDelegate(),
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

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/search_home_delegate.png'),
    );
  });

  testWidgets('flyout open', (tester) async {
    await pump(
      tester,
      history: ['Dune Part Two', 'Arrival', 'The Bear', 'Severance'],
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    // The whole app, not just the SearchScreen: the flyout renders in the
    // ROOT overlay, which is a sibling of the screen's subtree, so capturing
    // the screen alone photographs the page with the panel cropped off.
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/search_desktop_flyout.png'),
    );
  });
}
