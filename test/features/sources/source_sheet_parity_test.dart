import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/network/link_probe_service.dart';
import 'package:skystream/core/nuvio/data/nuvio_stream_service.dart';
import 'package:skystream/core/nuvio/models/nuvio_models.dart';
import 'package:skystream/core/theme/app_theme.dart';
import 'package:skystream/features/details/presentation/tmdb_details_controller.dart';
import 'package:skystream/features/details/presentation/widgets/episode_picker_sheet.dart';
import 'package:skystream/features/sources/presentation/plugin_sources_sheet.dart';
import 'package:skystream/features/sources/presentation/source_sheet_widgets.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

class _FakeNuvio implements NuvioStreamService {
  @override
  Stream<NuvioProgress> resolve({
    required String tmdbId,
    required String mediaType,
    int? season,
    int? episode,
  }) async* {
    yield const NuvioProgress(
      streams: [
        NuvioStreamResult(
          scraperId: 'a',
          scraperName: 'alpha',
          title: 'A',
          url: 'https://c/a.mkv',
          quality: '1080p',
        ),
      ],
      completedCount: 1,
      totalCount: 1,
    );
  }

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeProbe implements LinkProbeService {
  @override
  Future<LinkProbeResult> probe(String url, {Map<String, String>? headers}) =>
      Future.value(const LinkProbeResult(reachable: true));
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeCtl extends TmdbDetailsController {
  @override
  TmdbDetailsState build(int movieId, {String? source}) => TmdbDetailsState(
    selectedSeason: 1,
    episodesFuture: Future.value({
      'episodes': [
        {'episode_number': 1, 'name': 'Pilot', 'overview': 'x'},
      ],
    }),
  );
}

Future<Map<String, Rect>> _measure(
  WidgetTester tester,
  Widget sheet,
  String titleText,
) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        nuvioStreamServiceProvider.overrideWithValue(_FakeNuvio()),
        linkProbeServiceProvider.overrideWithValue(_FakeProbe()),
        tmdbDetailsControllerProvider(7).overrideWith(_FakeCtl.new),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.createDarkTheme(null),
        home: Builder(builder: (_) => sheet),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));

  final buttons =
      find
          .descendant(
            of: find.byType(GlassSheetScaffold),
            matching: find.byType(IconButton),
          )
          .evaluate()
          .map((e) => tester.getRect(find.byWidget(e.widget)))
          .toList()
        ..sort((a, b) => a.left.compareTo(b.left));
  // Each header button carries a filled circle, so a gap of zero would put
  // two circles edge to edge and read as one lozenge.
  for (var i = 1; i < buttons.length; i++) {
    expect(
      buttons[i].left - buttons[i - 1].right,
      kSourceSheetHeaderGap,
      reason: 'header buttons must not touch',
    );
  }
  return {
    'panel': tester.getRect(find.byType(GlassSheetScaffold)),
    'pane': tester.getRect(find.byType(BackdropFilter).first),
    'title': tester.getRect(find.text(titleText)),
    // The button's own box: with a filled background that circle is what the
    // eye lines up, not the glyph centred inside it.
    'close': tester.getRect(
      find
          .ancestor(
            of: find.byIcon(Icons.close_rounded),
            matching: find.byType(IconButton),
          )
          .first,
    ),
    'row': tester.getRect(find.byType(GlassRow).first),
  };
}

/// The three source sheets are one design shown at three moments - which
/// episode, which Nuvio link, which Stremio link - and they had drifted anyway,
/// because the glass panel was ninety lines of chrome copied into each. By the
/// time anyone looked, the light pane was 0xA6F4F4F7 in one and 0xA6F4F4F8 in
/// another, the ink 0xFF16161C against 0xFF15151C, the focus fill 0xFFE6E6EE
/// against 0xFFE2E2EA, one still dropped a 50%-black shadow under a pale panel,
/// and the filter chips had four copies of the same forty lines - every one of
/// them leaving the checkmark to the theme, which is why the tick was invisible
/// in both brightnesses.
///
/// None of that was decided. It was copied and then not merged.
///
/// Two gates here. The first measures two of the sheets against each other, so
/// a change to the shared scaffold that moves one has to move both. The second
/// reads the three sources, because the failure mode is not a wrong number -
/// it is someone inlining the chrome again, and no rendered assertion catches
/// that until it has already drifted.
void main() {
  testWidgets('the picker and the Nuvio sheet render identically', (
    tester,
  ) async {
    final sheet = await _measure(
      tester,
      PluginSourcesSheet(
        target: MultimediaItem(title: 'T', url: '', posterUrl: '', tmdbId: 1),
      ),
      'Nuvio Sources',
    );
    final picker = await _measure(
      tester,
      Builder(
        builder: (ctx) => EpisodePickerSheet(
          movieId: 7,
          seasons: const [
            {'season_number': 1},
          ],
          target: MultimediaItem(title: 'T', url: '', posterUrl: ''),
          hostContext: ctx,
        ),
      ),
      'Select Episode',
    );

    for (final k in ['pane', 'title', 'close', 'row']) {
      final a = sheet[k]!, b = picker[k]!;
      debugPrint(
        'P $k  sheet L=${(a.left - sheet['pane']!.left).toStringAsFixed(1)} '
        'R=${(sheet['pane']!.right - a.right).toStringAsFixed(1)} '
        '| picker L=${(b.left - picker['pane']!.left).toStringAsFixed(1)} '
        'R=${(picker['pane']!.right - b.right).toStringAsFixed(1)}',
      );
    }
    debugPrint('P paneSheet=${sheet['pane']} panePicker=${picker['pane']}');
    debugPrint(
      'P titleCy sheet=${sheet['title']!.center.dy - sheet['pane']!.top} '
      'closeCy=${sheet['close']!.center.dy - sheet['pane']!.top} '
      '| picker title=${picker['title']!.center.dy - picker['pane']!.top} '
      'close=${picker['close']!.center.dy - picker['pane']!.top}',
    );

    // same panel box
    expect(sheet['pane']!.size, picker['pane']!.size);
    // same header geometry, measured relative to the panel
    for (final k in ['title', 'close', 'row']) {
      expect(
        sheet[k]!.left - sheet['pane']!.left,
        picker[k]!.left - picker['pane']!.left,
        reason: 'left inset must match',
      );
    }
    // Right edge only where the width is not the title string itself.
    for (final k in ['close', 'row']) {
      expect(
        sheet['pane']!.right - sheet[k]!.right,
        picker['pane']!.right - picker[k]!.right,
        reason: 'right inset must match',
      );
    }
    for (final m in [sheet, picker]) {
      // the X sits on the title line
      expect(m['close']!.center.dy, closeTo(m['title']!.center.dy, 0.5));
      // ...and clears the panel by the gutter on both axes. The panel's
      // corner is 28, so a close button pushed out to 2 dp - which is what
      // happens if the end inset compensates for a BARE glyph's slack after
      // the button has been given a filled circle - is clipped by the curve.
      expect(
        m['close']!.top - m['pane']!.top,
        16,
        reason: 'the close button must clear the panel top by the gutter',
      );
      expect(
        m['pane']!.right - m['close']!.right,
        16,
        reason: 'the close button must clear the panel end by the gutter',
      );
    }
  });

  group('every source sheet is built from the shared parts', () {
    const kSharedWidgets =
        'lib/features/sources/presentation/source_sheet_widgets.dart';
    const sheets = <String>[
      'lib/features/sources/presentation/plugin_sources_sheet.dart',
      'lib/features/details/presentation/widgets/episode_picker_sheet.dart',
      'lib/features/addons/presentation/addon_sources_sheet.dart',
    ];

    test('each uses the shared scaffold, row and chip', () {
      for (final path in sheets) {
        final source = File(path).readAsStringSync();
        expect(
          source,
          contains('GlassSheetScaffold('),
          reason: '$path must be drawn in the shared panel',
        );
        expect(
          source,
          contains('GlassRow('),
          reason: '$path must draw its rows in the shared shell',
        );
      }
    });

    test('none of them rebuilds the chrome it was given', () {
      // Patterns, not substrings: SourceFilterChip contains "FilterChip".
      const banned = <String, String>{
        r'return Dialog\(': 'the scaffold owns the dialog',
        r'BackdropFilter\(': 'the scaffold owns the blur',
        r'(?<![A-Za-z])FilterChip\(': 'SourceFilterChip owns the pills',
        r'class _Glass': 'GlassPalette is the one palette',
      };
      for (final path in sheets) {
        final source = File(path).readAsStringSync();
        for (final entry in banned.entries) {
          expect(
            RegExp(entry.key).hasMatch(source),
            isFalse,
            reason:
                '$path re-declares what it was given - ${entry.value}. That '
                'is how the three sheets drifted the first time; put it in '
                'source_sheet_widgets.dart so every sheet gets it.',
          );
        }
      }
    });

    test('none of them hand-picks a horizontal inset', () {
      // The gutter is kSourceSheetGutter. A literal here is how one header
      // ended up at 18 left and 12 right while its list sat at 14.
      final offenders = <String>[];
      for (final path in sheets) {
        for (final (i, line) in File(path).readAsLinesSync().indexed) {
          if (RegExp(r'EdgeInsets\.fromLTRB\(\s*1[248]\s*,').hasMatch(line) ||
              RegExp(r'EdgeInsets\.symmetric\(horizontal:\s*1[48]\s*[,)]')
                  .hasMatch(line)) {
            offenders.add('$path:${i + 1}: ${line.trim()}');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'use kSourceSheetGutter:\n  ${offenders.join('\n  ')}',
      );
    });

    test('colour comes from the scheme, not from literals', () {
      // Material 3, like the rest of the app. These sheets used to carry a
      // palette of their own - a Tailwind-ish green, amber, teal and purple,
      // two hand-mixed inks per brightness, and the player's fixed accent -
      // which is what made them the one corner that ignored the user's theme
      // and never picked up dynamic colour.
      //
      // The frosted pane is the one exception, and it lives in exactly one
      // place: it is a translucent tint over whatever is BEHIND the sheet, not
      // a surface the scheme has a role for.
      final offenders = <String>[];
      for (final path in [...sheets, kSharedWidgets]) {
        for (final (i, line) in File(path).readAsLinesSync().indexed) {
          final code = line.split('//').first;
          if (code.contains('Color(0xA6')) continue; // the pane
          final hit =
              RegExp(r'Color\(0x').hasMatch(code) ||
              RegExp(r'Colors\.(?!transparent)[a-z]').hasMatch(code);
          if (hit) offenders.add('$path:${i + 1}: ${line.trim()}');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'use a ColorScheme role:\n  ${offenders.join('\n  ')}',
      );
    });
  });
}
