import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/features/library/presentation/library_provider.dart';
import 'package:skystream/features/library/presentation/library_state.dart';
import 'package:skystream/features/library/presentation/widgets/bookmarks_tab.dart';
import 'package:skystream/features/settings/presentation/general_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:skystream/shared/widgets/cards_wrapper.dart';

/// The bookmarks list, without Hive underneath it.
///
/// [setItems] is what a details page does through `Library.refresh()` when the
/// viewer toggles a bookmark: the state is replaced with a list of a different
/// length, and every card after the change point lands on a lower index.
class _FakeLibrary extends Library {
  _FakeLibrary(this._items);
  List<MultimediaItem> _items;

  @override
  LibraryState build() => _stateFor(_items);

  void setItems(List<MultimediaItem> items) {
    _items = items;
    state = _stateFor(_items);
  }

  static LibraryState _stateFor(List<MultimediaItem> items) =>
      items.isEmpty ? const LibraryEmpty() : LibrarySuccess(items);
}

String _url(int i) => 'https://fake.test/$i';

MultimediaItem _item(int i) => MultimediaItem(
  title: 'Title $i',
  url: _url(i),
  posterUrl: '',
  contentType: MultimediaContentType.movie,
);

List<MultimediaItem> _items(Iterable<int> indices) =>
    indices.map(_item).toList();

List<MultimediaItem> _thirtyItems() => _items(List<int>.generate(30, (i) => i));

/// The `Focus` node `CardsWrapper` installed for the card showing [url].
FocusNode _cardNode(WidgetTester tester, String url) {
  return tester
      .widget<Focus>(
        find
            .descendant(
              of: find.byKey(ValueKey<String>(url)),
              matching: find.byType(Focus),
            )
            .first,
      )
      .focusNode!;
}

/// The title of the card that currently owns the highlight, or a description
/// of whatever else has it — the failure that matters is "the highlight is
/// somewhere that is not the card the viewer left from", and naming what has
/// it instead makes the diagnostic readable.
String _focusedCardTitle() {
  final BuildContext? context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return '<no focus>';
  if (context.findAncestorWidgetOfExactType<CardsWrapper>() == null) {
    return '<not a card: ${context.widget.runtimeType}>';
  }
  final titles = <String>[];
  void visit(Element element) {
    final Widget widget = element.widget;
    if (widget is Text && widget.data != null) titles.add(widget.data!);
    element.visitChildren(visit);
  }

  context.visitChildElements(visit);
  return titles.isEmpty ? '<card with no title>' : titles.first;
}

/// `/` is the grid, `/details` stands in for the details page — which, as far
/// as focus is concerned, is exactly what it is: a pushed opaque route.
///
/// [gridMounted] lets a test take the tab out of the tree while the details
/// page is up, the way the shell does when it changes branch.
GoRouter _routerFor(ValueListenable<bool> gridMounted) => GoRouter(
  initialLocation: '/',
  routes: <RouteBase>[
    GoRoute(
      path: '/',
      builder: (_, _) => Scaffold(
        body: ValueListenableBuilder<bool>(
          valueListenable: gridMounted,
          builder: (_, bool mounted, _) =>
              mounted ? const BookmarksTab() : const SizedBox.shrink(),
        ),
      ),
    ),
    GoRoute(
      path: '/details',
      builder: (_, _) => const Scaffold(body: Text('details page')),
    ),
  ],
);

/// Pumps the real grid under a real router.
///
/// [profile] decides whether this is a device with a highlight to restore; a
/// television is the default because that is the surface the behaviour exists
/// for.
Future<GoRouter> _pumpGrid(
  WidgetTester tester, {
  required _FakeLibrary library,
  DeviceProfile profile = const DeviceProfile(isTv: true),
  ValueListenable<bool>? gridMounted,
}) async {
  final container = ProviderContainer(
    overrides: [
      libraryProvider.overrideWith(() => library),
      generalSettingsProvider.overrideWithValue(const GeneralSettings()),
      deviceProfileProvider.overrideWithValue(AsyncValue.data(profile)),
    ],
  );
  addTearDown(container.dispose);

  final router = _routerFor(gridMounted ?? ValueNotifier<bool>(true));
  addTearDown(router.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  // Never pumpAndSettle here: the poster placeholders shimmer forever, so a
  // settle would time out rather than tell us anything.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return router;
}

/// Focuses the card for [url] and presses SELECT on it, which is how a remote
/// opens a poster: `CardsWrapper` turns the key down into the card's `onTap`.
Future<void> _openFromCard(WidgetTester tester, String url) async {
  _cardNode(tester, url).requestFocus();
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.select);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _popBack(WidgetTester tester, GoRouter router) async {
  router.pop();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUp(() {
    // A television is in traditional highlight mode; the default in a widget
    // test resolves to touch, where the ring is suppressed entirely.
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  });

  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  group('the bookmarks grid returns the highlight to the card it was left '
      'from', () {
    testWidgets('after the grid rebuilt its tiles while the viewer was away', (
      tester,
    ) async {
      // The journey: the viewer is partway down the grid, opens a poster, and
      // while they are away the bookmark list changes under it — a bookmark
      // dropped on a details page, which is the one thing that page does to
      // this list. Every card after the change point moves down one index, so
      // the tile that had the highlight is torn down and its FocusNode
      // disposed with it. The framework's own memory of the focused child dies
      // there, and without a restore of our own the next D-pad press starts
      // again from the first poster.
      final library = _FakeLibrary(_thirtyItems());
      final router = await _pumpGrid(tester, library: library);

      await _openFromCard(tester, _url(4));
      expect(find.text('details page'), findsOneWidget);

      library.setItems(_items(List<int>.generate(29, (i) => i + 1)));
      await tester.pump();

      await _popBack(tester, router);

      expect(_focusedCardTitle(), 'Title 4');
      expect(_cardNode(tester, _url(4)).hasPrimaryFocus, isTrue);
    });

    testWidgets('but never on a touch device, where no highlight was showing', (
      tester,
    ) async {
      // A phone: the viewer tapped the poster, nothing was focused while they
      // did it, and a ring appearing on the way back is a control they never
      // asked for — and a new starting point for any key they press later.
      final library = _FakeLibrary(_thirtyItems());
      final router = await _pumpGrid(
        tester,
        library: library,
        profile: const DeviceProfile(),
      );

      await _openFromCard(tester, _url(4));
      library.setItems(_items(List<int>.generate(29, (i) => i + 1)));
      await tester.pump();

      await _popBack(tester, router);

      expect(_focusedCardTitle(), isNot('Title 4'));
      expect(_cardNode(tester, _url(4)).hasPrimaryFocus, isFalse);
    });
  });

  group('restoring is a safe no-op when there is nothing to restore to', () {
    testWidgets(
      'the bookmark was removed on the details page: no highlight then, and '
      'none stolen later either',
      (tester) async {
        // Two halves, and the second is the one that bites. Asking a node with
        // no parent for focus does not throw — it quietly arms the framework's
        // `_requestFocusWhenReparented`, and the highlight is handed over the
        // instant that cell is built again. Here the viewer deletes the
        // bookmark on the details page, comes back, moves the highlight
        // somewhere of their own choosing, and the title is re-bookmarked from
        // elsewhere. The card reappearing must not snatch the highlight off
        // the card they are on. The same guard covers the other two ways the
        // target can be missing — scrolled out of the build, or its tile
        // disposed — because all three end at a node with no live cell.
        //
        // A short list, so every card is built and the re-appearing one is a
        // live cell rather than an unbuilt index; and re-added at the END,
        // which is where a deleted-then-written Hive key lands, so the card
        // the viewer chose keeps its own tile and its own highlight.
        final library = _FakeLibrary(_items(const [0, 1, 2, 3, 4, 5, 6, 7]));
        final router = await _pumpGrid(tester, library: library);

        await _openFromCard(tester, _url(4));

        library.setItems(_items(const [0, 1, 2, 3, 5, 6, 7]));
        await tester.pump();

        await _popBack(tester, router);
        expect(find.byKey(ValueKey<String>(_url(4))), findsNothing);

        _cardNode(tester, _url(7)).requestFocus();
        await tester.pump();
        expect(_focusedCardTitle(), 'Title 7');

        library.setItems(_items(const [0, 1, 2, 3, 5, 6, 7, 4]));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.byKey(ValueKey<String>(_url(4))), findsOneWidget);
        expect(_focusedCardTitle(), 'Title 7');
        expect(_cardNode(tester, _url(4)).hasPrimaryFocus, isFalse);
      },
    );

    testWidgets('the grid itself went away while the viewer was on the '
        'details page', (tester) async {
      // The tab can be gone by the time the details page is popped — the shell
      // changes branch under it, or the screen is replaced. The push future
      // still completes and still runs our continuation, on a State that no
      // longer has a context to ask anything of.
      final gridMounted = ValueNotifier<bool>(true);
      addTearDown(gridMounted.dispose);
      final library = _FakeLibrary(_thirtyItems());
      final router = await _pumpGrid(
        tester,
        library: library,
        gridMounted: gridMounted,
      );

      await _openFromCard(tester, _url(4));

      gridMounted.value = false;
      await tester.pump();
      expect(find.byType(BookmarksTab), findsNothing);

      await _popBack(tester, router);

      expect(tester.takeException(), isNull);
    });
  });
}
