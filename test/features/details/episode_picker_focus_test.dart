import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/theme/app_theme.dart';
import 'package:skystream/features/details/presentation/tmdb_details_controller.dart';
import 'package:skystream/features/details/presentation/widgets/episode_picker_sheet.dart';
import 'package:skystream/features/sources/presentation/source_sheet_widgets.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// The picker is reached with a remote as often as with a finger - it is what
/// a series opens on a television - so every row has to be exactly one stop of
/// the D-pad and the walk has to terminate somewhere sane.
///
/// One stop is not free: [GlassRow] wraps its content in an [InkWell], and a
/// focusable InkWell publishes a second node over the same rect as the
/// caller's [DpadFocusable]. DOWN then lands on the InkWell, paints no focus
/// ring, and the viewer presses DOWN again to get anywhere - every row costing
/// two presses and flashing nothing on the first. `canRequestFocus: false` is
/// what prevents it, and this is the test that notices if it goes.
class _FakeController extends TmdbDetailsController {
  @override
  TmdbDetailsState build(int movieId, {String? source}) => TmdbDetailsState(
    selectedSeason: 1,
    episodesFuture: Future.value({
      'episodes': [
        for (var i = 1; i <= 3; i++)
          {
            'episode_number': i,
            'name': 'Episode $i',
            'overview': 'Overview $i',
            'runtime': 45,
          },
      ],
    }),
  );

  @override
  Future<void> fetchEpisodes(int season, {String? source}) async {
    state = state.copyWith(selectedSeason: season);
  }
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await _flush(tester);
}

Rect? _focusedRect() {
  final node = FocusManager.instance.primaryFocus;
  if (node == null || !node.context!.mounted) return null;
  return node.rect;
}

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(960, 540);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tmdbDetailsControllerProvider(7).overrideWith(_FakeController.new),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.createDarkTheme(null),
        home: Builder(
          builder: (ctx) => EpisodePickerSheet(
            movieId: 7,
            seasons: const [
              {'season_number': 1},
            ],
            target: MultimediaItem(title: 'Show', url: '', posterUrl: ''),
            hostContext: ctx,
          ),
        ),
      ),
    ),
  );
  await _flush(tester);
}

void main() {
  testWidgets('every episode row is one D-pad stop, not two', (tester) async {
    await _pump(tester);

    Rect rowRect(String title) => tester.getRect(
      find
          .ancestor(of: find.text(title), matching: find.byType(GlassRow))
          .first,
    );

    // The first row autofocuses, so the walk starts there.
    expect(_focusedRect(), rowRect('Episode 1'));

    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(
      _focusedRect(),
      rowRect('Episode 2'),
      reason:
          'one DOWN must move a whole row. Landing on an unpainted node over '
          'the same rect means GlassRow\'s InkWell became focusable.',
    );

    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focusedRect(), rowRect('Episode 3'));

    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focusedRect(), rowRect('Episode 2'));
  });

  testWidgets('the close button is reachable from the list', (tester) async {
    await _pump(tester);

    // UP off the top of the list must reach the sheet's own chrome rather
    // than dead-ending on the first row.
    for (var i = 0; i < 6; i++) {
      await _press(tester, LogicalKeyboardKey.arrowUp);
      final focused = FocusManager.instance.primaryFocus?.context?.widget;
      if (focused != null) {
        final close = find.byIcon(Icons.close_rounded);
        if (close.evaluate().isNotEmpty &&
            _focusedRect() != null &&
            _focusedRect()!.overlaps(tester.getRect(close))) {
          return; // reached the close button
        }
      }
    }
    fail('the close button was not reachable by pressing UP from the list');
  });
}
