import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/search/presentation/search_provider.dart';
import 'package:skystream/features/search/presentation/widgets/search_header_bar.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

void main() {
  late TextEditingController controller;
  late FocusNode searchFocus;
  late FocusNode clearFocus;
  late FocusNode moviesFocus;
  late FocusNode liveFocus;

  setUp(() {
    controller = TextEditingController();
    searchFocus = FocusNode();
    clearFocus = FocusNode();
    moviesFocus = FocusNode();
    liveFocus = FocusNode();
  });

  tearDown(() {
    controller.dispose();
    searchFocus.dispose();
    clearFocus.dispose();
    moviesFocus.dispose();
    liveFocus.dispose();
  });

  Future<void> pumpBar(
    WidgetTester tester, {
    required bool isCompact,
    Widget? flyout,
    double width = 1280,
  }) async {
    tester.view.physicalSize = Size(width, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          searchResultsProvider.overrideWith(
            (ref) => Stream.value(const SearchAggregateState()),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.dark(),
          home: Scaffold(
            body: SearchHeaderBar(
              textController: controller,
              searchFocusNode: searchFocus,
              clearButtonFocusNode: clearFocus,
              moviesShowsFocusNode: moviesFocus,
              liveTvFocusNode: liveFocus,
              isCompact: isCompact,
              flyout: flyout,
              onSubmitted: (_) {},
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // The bar's root went from a Column to a Row carrying an Expanded, so the
  // home dashboard's compact copy - which has no scope pill to sit beside -
  // is the case most likely to have been broken by the change.
  group('compact (home dashboard header)', () {
    testWidgets('lays out with no scope pill', (tester) async {
      await pumpBar(tester, isCompact: true);

      expect(tester.takeException(), isNull);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byType(SearchScopeSwitcher), findsNothing);
    });

    testWidgets('keeps its narrow width', (tester) async {
      await pumpBar(tester, isCompact: true);

      // 360 dp of field, not the 940 the search tab's bar is allowed.
      expect(tester.getRect(find.byType(TextField)).width, lessThan(400));
    });

    testWidgets('shows no flyout when it is given none', (tester) async {
      await pumpBar(tester, isCompact: true);

      expect(find.byKey(const ValueKey('searchFlyout')), findsNothing);
    });
  });

  group('full (search tab)', () {
    testWidgets('carries the scope pill', (tester) async {
      await pumpBar(tester, isCompact: false);

      expect(tester.takeException(), isNull);
      expect(find.byType(SearchScopeSwitcher), findsOneWidget);
    });

    testWidgets('hangs whatever flyout it is handed under the field', (
      tester,
    ) async {
      await pumpBar(
        tester,
        isCompact: false,
        flyout: const SizedBox(height: 120, child: Text('panel')),
      );

      final panel = find.byKey(const ValueKey('searchFlyout'));
      expect(panel, findsOneWidget);
      expect(
        find.descendant(of: panel, matching: find.text('panel')),
        findsOneWidget,
      );
      expect(
        tester.getRect(panel).top,
        greaterThan(tester.getRect(find.byType(TextField)).bottom),
      );
    });

    // The pill sat hard against the window edge - and against the scrollbar
    // living there - at any width where the bar uses all 940 dp it is given.
    testWidgets('keeps the pill off the window edge', (tester) async {
      const width = 900.0;
      await pumpBar(tester, isCompact: false, width: width);

      final pill = tester.getRect(find.byType(SearchScopeSwitcher));
      final field = tester.getRect(find.byType(TextField));

      expect(
        width - pill.right,
        greaterThanOrEqualTo(20),
        reason: 'the pill needs a gutter on its right',
      );
      expect(
        field.left,
        greaterThanOrEqualTo(20),
        reason: 'and the field the matching one on its left',
      );
    });

    testWidgets('a narrow window still lays the bar out without overflow', (
      tester,
    ) async {
      // 640 dp clears the tablet breakpoint by 40, so the field and the
      // 310 dp pill have to share a width barely wider than the pill.
      await pumpBar(tester, isCompact: false, width: 640);

      expect(tester.takeException(), isNull);
      expect(find.byType(SearchScopeSwitcher), findsOneWidget);
    });
  });
}
