import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/data/addon_repository.dart';
import 'package:skystream/core/addons/data/addon_stream_service.dart';
import 'package:skystream/core/addons/models/addon_stream_source.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/network/link_probe_service.dart';
import 'package:skystream/core/theme/app_theme.dart';
import 'package:skystream/features/addons/presentation/addon_sources_sheet.dart';
import 'package:skystream/features/sources/presentation/source_sheet_widgets.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// The Stremio sheet is one of three built from the same parts, and was the
/// only one with no D-pad test of its own.
///
/// The case that matters is a row's LAST control. RIGHT there used to fall
/// through to Flutter's default policy, which keeps any candidate whose CENTRE
/// passes the current rect's right edge - so whether RIGHT did nothing or
/// jumped up to the sheet's header depended on where the header's buttons
/// happened to sit. Moving them 10 dp to line their glyphs up with the gutter
/// was enough to break it on the Nuvio sheet, which is how this was found.
class _FakeService implements AddonStreamService {
  @override
  Stream<AddonStreamProgress> resolve({
    required List<dynamic> addons,
    required AddonStreamRequest request,
    bool forceRefresh = false,
    dynamic cancelToken,
  }) async* {
    yield const AddonStreamProgress(
      streams: [
        AddonStreamSource(
          addonId: 'a',
          addonName: 'Torrentio',
          name: 'Alpha 1080p',
          title: 'Alpha',
          url: 'https://cdn.test/alpha.mkv',
        ),
        AddonStreamSource(
          addonId: 'a',
          addonName: 'Torrentio',
          name: 'Beta 1080p',
          title: 'Beta',
          url: 'https://cdn.test/beta.mkv',
        ),
      ],
      completedCount: 1,
      totalCount: 1,
    );
  }

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeRepo extends AddonRepository {
  @override
  AddonsState build() => const AddonsState(isLoading: false);
}

class _FakeProbe implements LinkProbeService {
  @override
  Future<LinkProbeResult> probe(String url, {Map<String, String>? headers}) =>
      Future.value(const LinkProbeResult(reachable: true));
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
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

Rect _focused() => FocusManager.instance.primaryFocus!.rect;

void main() {
  testWidgets("RIGHT on a row's last control stays put", (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          addonStreamServiceProvider.overrideWithValue(_FakeService()),
          addonRepositoryProvider.overrideWith(_FakeRepo.new),
          linkProbeServiceProvider.overrideWithValue(_FakeProbe()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.createDarkTheme(null),
          home: AddonSourcesSheet(
            item: MultimediaItem(title: 'T', url: '', posterUrl: ''),
            request: const AddonStreamRequest(type: 'movie', contentId: 'tt1'),
          ),
        ),
      ),
    );
    await _flush(tester);

    await _press(tester, LogicalKeyboardKey.arrowDown);
    // Whichever row holds focus - the first one autofocuses, so DOWN lands on
    // the second. What matters is that focus is on a whole row, not on some
    // unpainted node inside one.
    final rows = find
        .byType(GlassRow)
        .evaluate()
        .map((e) => tester.getRect(find.byWidget(e.widget)))
        .toList();
    final row = _focused();
    expect(
      rows,
      contains(row),
      reason: 'DOWN should land on a whole row, not a node inside one',
    );

    await _press(tester, LogicalKeyboardKey.arrowRight);
    final play = _focused();
    expect(play, isNot(row), reason: 'RIGHT should reach the Play chip');

    await _press(tester, LogicalKeyboardKey.arrowRight);
    final download = _focused();
    expect(
      download,
      isNot(play),
      reason: 'RIGHT again should reach the Download chip',
    );

    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(
      _focused(),
      download,
      reason:
          'RIGHT past the last control must stay put, not escape into the '
          'sheet header',
    );

    await _press(tester, LogicalKeyboardKey.arrowLeft);
    expect(_focused(), play, reason: 'LEFT walks back along the row');
  });
}
