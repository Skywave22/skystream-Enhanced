import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/source_row_status.dart';
import 'package:skystream/features/player/presentation/vlc/player_startup_view.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// The one view the player shows from "getting links" until the first frame,
/// and again when every source has failed.
///
/// Rendered on its own here: it is pure data in, callbacks out, so what it
/// shows and how it answers can be pinned without standing a player up.
const String _backdrop = 'https://img.example/backdrop.jpg';
const String _logo = 'https://img.example/logo.png';

const Size _phone = Size(390, 844);
const Size _desktop = Size(1280, 800);
const Size _television = Size(960, 540);

List<StartupRow> _rows(
  int count, {
  SourceReachability reachability = SourceReachability.notChecked,
  SourcePlayState playState = SourcePlayState.untried,
}) => [
  for (var i = 0; i < count; i++)
    StartupRow(
      label: 'Source $i',
      reachability: reachability,
      playState: playState,
    ),
];

Future<AppLocalizations> _english() =>
    AppLocalizations.delegate.load(const Locale('en'));

void main() {
  late List<int> picks;
  late int retries;
  late int doubleClicks;

  setUp(() {
    picks = <int>[];
    retries = 0;
    doubleClicks = 0;
  });

  Widget view({
    List<StartupRow> rows = const <StartupRow>[],
    int? currentIndex,
    bool failed = false,
    bool isTv = false,
    String? backdropUrl,
    String? logoUrl,
    String? status = 'Checking links…',
  }) => PlayerStartupView(
    title: 'A Film',
    logoUrl: logoUrl,
    backdropUrl: backdropUrl,
    status: status,
    rows: rows,
    currentIndex: currentIndex,
    failed: failed,
    isTv: isTv,
    onPick: picks.add,
    onBack: () {},
    onRetry: () => retries++,
    onDoubleClick: () => doubleClicks++,
  );

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Size size = _desktop,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    );
    // Never settle: the spinners are endless and the artwork never resolves
    // under test.
    await tester.pump();
  }

  Finder row(int index) => find.byKey(PlayerStartupView.rowKey(index));

  testWidgets('there is no Skip: the rows are how the viewer moves on', (
    tester,
  ) async {
    final l10n = await _english();
    await pump(tester, view(rows: _rows(3), currentIndex: 0));

    expect(find.text(l10n.playerSkipSource), findsNothing);
    expect(find.text(l10n.skip), findsNothing);
  });

  // The rows are plainly a list of links; a line saying so under it was noise.
  testWidgets('no hint under the list', (tester) async {
    await pump(tester, view(rows: _rows(3), currentIndex: 0));

    expect(find.text('Select a link to play it'), findsNothing);
  });

  testWidgets('selecting a row plays that row', (tester) async {
    await pump(tester, view(rows: _rows(3), currentIndex: 0));

    await tester.tap(row(2));
    await tester.pump(kDoubleTapTimeout);

    expect(picks, <int>[2]);
  });

  testWidgets('each row says what the check found and how playing went', (
    tester,
  ) async {
    final l10n = await _english();
    await pump(
      tester,
      view(
        rows: const <StartupRow>[
          StartupRow(
            label: 'a',
            reachability: SourceReachability.reachable,
            playState: SourcePlayState.failed,
          ),
          StartupRow(
            label: 'b',
            reachability: SourceReachability.unreachable,
            playState: SourcePlayState.opening,
          ),
          StartupRow(label: 'c', reachability: SourceReachability.checking),
          StartupRow(label: 'd', reachability: SourceReachability.notChecked),
        ],
        currentIndex: 1,
      ),
    );

    for (final label in <String>[
      l10n.playerSourceReachable,
      l10n.playerSourceUnplayable,
      l10n.unknown,
      l10n.playerSourceOpening,
      l10n.playerSourceChecking,
    ]) {
      expect(
        find.text(label, skipOffstage: false),
        findsOneWidget,
        reason: label,
      );
    }
  });

  // On this screen a blank already reads as "not asked yet", and every row
  // past the top three saying so is noise. The Sources panel still says it.
  testWidgets('a source nobody has checked leaves the column blank', (
    tester,
  ) async {
    final l10n = await _english();
    await pump(tester, view(rows: _rows(2)));

    expect(find.text(l10n.playerSourceNotChecked), findsNothing);
    expect(
      find.descendant(of: row(0), matching: find.byIcon(Icons.remove_rounded)),
      findsNothing,
    );
  });

  testWidgets('and blank on a narrow list too', (tester) async {
    await pump(tester, view(rows: _rows(2)), size: _phone);

    expect(
      find.descendant(of: row(0), matching: find.byIcon(Icons.remove_rounded)),
      findsNothing,
    );
  });

  // The bug the split exists for: with one merged status, "Opening…" replaced
  // the row's check result, so the link being opened looked less proven than
  // the ones below it that had passed the same check.
  testWidgets('the row being opened still says what its check found', (
    tester,
  ) async {
    final l10n = await _english();
    await pump(
      tester,
      view(
        rows: [
          const StartupRow(
            label: 'first',
            reachability: SourceReachability.reachable,
            playState: SourcePlayState.opening,
          ),
          ..._rows(2, reachability: SourceReachability.reachable),
        ],
        currentIndex: 0,
      ),
    );

    Finder inRow(String text) =>
        find.descendant(of: row(0), matching: find.text(text));
    expect(inRow(l10n.playerSourceReachable), findsOneWidget);
    expect(inRow(l10n.playerSourceOpening), findsOneWidget);
    expect(
      tester.getTopLeft(inRow(l10n.playerSourceReachable)).dx,
      lessThan(tester.getTopLeft(inRow(l10n.playerSourceOpening)).dx),
      reason: 'reachability is the first column, the play state the second',
    );
  });

  testWidgets('a row nobody has opened says nothing about playing', (
    tester,
  ) async {
    final l10n = await _english();
    await pump(
      tester,
      view(rows: _rows(2, reachability: SourceReachability.reachable)),
    );

    for (final label in <String>[
      l10n.playerSourceOpening,
      l10n.playerSourceUnplayable,
    ]) {
      expect(
        find.descendant(of: row(1), matching: find.text(label)),
        findsNothing,
        reason: label,
      );
    }
  });

  // The row is its name, then what the check found, then how playing went.
  // An icon in front of the name repeated the last of those.
  testWidgets('nothing stands in front of the name', (tester) async {
    await pump(
      tester,
      view(
        rows: const <StartupRow>[
          StartupRow(
            label: 'Hubstream',
            reachability: SourceReachability.reachable,
            playState: SourcePlayState.failed,
          ),
          StartupRow(
            label: 'Other',
            reachability: SourceReachability.reachable,
          ),
        ],
      ),
    );

    for (final icon in <IconData>[
      Icons.close_rounded,
      Icons.radio_button_unchecked,
    ]) {
      expect(find.byIcon(icon), findsNothing, reason: '$icon');
    }
    final rowLeft = tester.getTopLeft(row(0)).dx;
    expect(
      tester.getTopLeft(find.text('Hubstream')).dx - rowLeft,
      lessThanOrEqualTo(16),
      reason: 'the name starts the row',
    );
  });

  testWidgets('on a narrow list the icons follow the name, check first', (
    tester,
  ) async {
    await pump(
      tester,
      view(
        rows: const <StartupRow>[
          StartupRow(
            label: 'Hubstream',
            reachability: SourceReachability.reachable,
            playState: SourcePlayState.failed,
          ),
        ],
      ),
      size: _phone,
    );

    final name = tester.getTopLeft(find.text('Hubstream')).dx;
    final check = tester.getTopLeft(find.byIcon(Icons.check_rounded)).dx;
    final played = tester.getTopLeft(find.byIcon(Icons.close_rounded)).dx;
    expect(name, lessThan(check));
    expect(check, lessThan(played));
  });

  // Two labelled columns take most of a portrait phone's list, and the link's
  // own name is the thing the viewer is choosing by.
  testWidgets('on a narrow list both columns become icons', (tester) async {
    final l10n = await _english();
    await pump(
      tester,
      view(
        rows: const <StartupRow>[
          StartupRow(
            label: 'first',
            reachability: SourceReachability.reachable,
            playState: SourcePlayState.failed,
          ),
        ],
      ),
      size: _phone,
    );

    expect(find.text(l10n.playerSourceReachable), findsNothing);
    expect(find.text(l10n.playerSourceUnplayable), findsNothing);
    expect(
      find.descendant(of: row(0), matching: find.byIcon(Icons.check_rounded)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row(0), matching: find.byIcon(Icons.close_rounded)),
      findsOneWidget,
    );
    // The row is one button, so its words merge into one label; the check's
    // word has to be in it.
    expect(
      find.bySemanticsLabel(RegExp(l10n.playerSourceReachable)),
      findsOneWidget,
      reason: 'a screen reader still hears the word',
    );
  });

  // With the list up its rows say what is happening, so the screen passes no
  // status - and an absent one must not leave an empty line in the column.
  testWidgets('no status, no status line', (tester) async {
    await pump(tester, view(rows: _rows(2), currentIndex: 0, status: null));

    expect(find.text('A Film'), findsOneWidget);
    expect(find.text(''), findsNothing);
  });

  testWidgets('while the plugin is still answering there is no list', (
    tester,
  ) async {
    await pump(tester, view(status: 'Getting links from Fake…'));

    expect(find.text('Getting links from Fake…'), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
  });

  group('the backdrop', () {
    Finder backdrop() => find.byWidgetPredicate(
      (w) => w is CachedNetworkImage && w.imageUrl == _backdrop,
    );

    testWidgets('is behind the view on a desktop', (tester) async {
      await pump(tester, view(backdropUrl: _backdrop));
      expect(backdrop(), findsOneWidget);
    });

    testWidgets('is behind the view on a television', (tester) async {
      await pump(
        tester,
        view(backdropUrl: _backdrop, isTv: true),
        size: _television,
      );
      expect(backdrop(), findsOneWidget);
    });

    testWidgets('is left off a phone', (tester) async {
      await pump(tester, view(backdropUrl: _backdrop), size: _phone);
      expect(backdrop(), findsNothing);
    });
  });

  testWidgets("the title's own logo is shown when it has one", (tester) async {
    await pump(tester, view(logoUrl: _logo));
    expect(
      find.byWidgetPredicate(
        (w) => w is CachedNetworkImage && w.imageUrl == _logo,
      ),
      findsOneWidget,
    );
  });

  testWidgets('every source failed: an error, not a spinner, and Retry', (
    tester,
  ) async {
    final l10n = await _english();
    await pump(
      tester,
      view(
        rows: _rows(3, playState: SourcePlayState.failed),
        failed: true,
        status: 'None of the 3 sources would play.',
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);

    await tester.tap(find.text(l10n.retry));
    await tester.pump(kDoubleTapTimeout);
    expect(retries, 1);
  });

  testWidgets('a double-click on the status line asks for full screen', (
    tester,
  ) async {
    await pump(tester, view(rows: _rows(3), currentIndex: 0));
    final at = tester.getCenter(find.text('Checking links…'));

    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(at);
    await tester.pump(kDoubleTapTimeout);

    expect(doubleClicks, 1);
    expect(picks, isEmpty);
  });

  group('the list', () {
    double rowTopInList(WidgetTester tester, int index) =>
        tester.getTopLeft(row(index)).dy -
        tester.getTopLeft(find.byType(ListView)).dy;

    double scrollOffset(WidgetTester tester) => tester
        .state<ScrollableState>(find.byType(Scrollable).last)
        .position
        .pixels;

    testWidgets('follows the current row, second from the top', (tester) async {
      final rows = _rows(20);
      await pump(tester, view(rows: rows, currentIndex: 0));
      expect(scrollOffset(tester), 0);

      await pump(tester, view(rows: rows, currentIndex: 10));
      await tester.pump(const Duration(milliseconds: 400));

      final rowHeight = tester.getSize(row(10)).height;
      expect(rowTopInList(tester, 10), moreOrLessEquals(rowHeight));
    });

    // The old overlay re-scrolled on every rebuild, so a status landing on any
    // row yanked the list back from wherever the viewer had scrolled it.
    testWidgets('stays where the viewer scrolled it until the current row '
        'changes', (tester) async {
      final rows = _rows(20);
      await pump(tester, view(rows: rows, currentIndex: 10));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.drag(find.byType(ListView), const Offset(0, 2000));
      await tester.pump(const Duration(milliseconds: 400));
      expect(scrollOffset(tester), 0);

      final changed = [...rows]
        ..[3] = const StartupRow(
          label: 'Source 3',
          reachability: SourceReachability.unreachable,
        );
      await pump(tester, view(rows: changed, currentIndex: 10));
      await tester.pump(const Duration(milliseconds: 400));

      expect(scrollOffset(tester), 0);
    });
  });

  group('on a television', () {
    bool focusIsIn(Finder finder) {
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused == null) return false;
      final target = finder.evaluate().single;
      var found = false;
      focused.visitAncestorElements((element) {
        if (element == target) found = true;
        return !found;
      });
      return found || focused == target;
    }

    testWidgets('the remote lands on the current row', (tester) async {
      await pump(
        tester,
        view(rows: _rows(5), currentIndex: 3, isTv: true),
        size: _television,
      );
      await tester.pump();

      expect(focusIsIn(row(3)), isTrue);
    });

    testWidgets('and on the first row while nothing is being opened', (
      tester,
    ) async {
      await pump(tester, view(rows: _rows(5), isTv: true), size: _television);
      await tester.pump();

      expect(focusIsIn(row(0)), isTrue);
    });

    testWidgets('Retry takes the remote once every source has failed', (
      tester,
    ) async {
      final l10n = await _english();
      await pump(
        tester,
        view(rows: _rows(3), currentIndex: 0, isTv: true),
        size: _television,
      );
      await tester.pump();

      await pump(
        tester,
        view(
          rows: _rows(3, playState: SourcePlayState.failed),
          failed: true,
          isTv: true,
        ),
        size: _television,
      );
      await tester.pump();

      expect(
        focusIsIn(
          find.ancestor(
            of: find.text(l10n.retry),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
          ),
        ),
        isTrue,
      );
    });
  });
}
