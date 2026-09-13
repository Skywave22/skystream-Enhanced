import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/network/link_probe_service.dart';
import 'package:skystream/core/nuvio/data/nuvio_stream_service.dart';
import 'package:skystream/core/nuvio/models/nuvio_models.dart';
import 'package:skystream/features/sources/presentation/plugin_sources_sheet.dart';
import 'package:skystream/features/sources/presentation/source_sheet_widgets.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// The chrome the two source sheets share.
///
/// The Nuvio sheet and the Stremio add-on sheet are the same component seen
/// twice - a user with a scraper and an add-on installed, which is the
/// intended configuration, opens both in one session. They were built from two
/// private copies of the same six types that had drifted apart in light mode:
/// different pane tint, a 50%-black drop shadow against an 18% one, and a
/// focused Play chip that was a dark fill on one and a white fill on the
/// other. On a television the focus treatment is the cursor, so that last one
/// was not cosmetic.
void main() {
  group('the Nuvio sheet is built from the shared chrome', () {
    testWidgets('the frosted pane and its shadow come from GlassPalette', (
      tester,
    ) async {
      // Light is where the two copies had diverged; in dark they still agreed.
      await _pumpSheet(tester, brightness: Brightness.light);

      final context = tester.element(find.byType(BackdropFilter));
      final glass = GlassPalette.of(context);

      final pane = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(BackdropFilter),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect(
        (pane.decoration as BoxDecoration).color,
        glass.pane,
        reason: 'the sheet is painting its own pane tint again',
      );

      final shadow = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((box) => box.decoration as BoxDecoration)
          .firstWhere((d) => (d.boxShadow ?? const []).isNotEmpty);
      expect(
        shadow.boxShadow!.single.color,
        glass.paneShadow,
        reason:
            'a 50%-black drop shadow under a pale panel is the add-on sheet '
            'and this one disagreeing about what a sheet looks like',
      );
    });

    testWidgets('the rows use the shared chip and badge widgets', (
      tester,
    ) async {
      await _pumpSheet(tester);

      // These are the *shared* types. A private copy would be a different
      // class with the same name, and would not be found here.
      expect(find.byType(DpadSourceButton), findsWidgets);
      expect(find.byType(QualityBadge), findsWidgets);
    });
  });

  /// A `ShaderMask` fades its child through an offscreen surface the size of
  /// the child. Over these sheets its child was a 0.5 dp hairline at 12% ink
  /// and all the mask did was ramp that line to nothing across the top and
  /// bottom 15% of the panel: an offscreen pass, on a scrolling list, for a
  /// gradient between two states that are both already at the edge of
  /// visible.
  group('no offscreen pass over the scrolling sheets', () {
    testWidgets('the Nuvio sheet paints no ShaderMask', (tester) async {
      await _pumpSheet(tester);
      expect(find.byType(ShaderMask), findsNothing);

      // The hairline itself stays - only its fade went.
      final hairline = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((box) => box.decoration as BoxDecoration)
          .where((d) => d.border != null)
          .where((d) => (d.border! as Border).top.width == 0.5);
      expect(
        hairline,
        isNotEmpty,
        reason: 'deleting the mask must not delete the edge it was masking',
      );
    });

    test('neither source sheet nor the episode picker re-adds one', () {
      const sheets = [
        'lib/features/sources/presentation/plugin_sources_sheet.dart',
        'lib/features/addons/presentation/addon_sources_sheet.dart',
        'lib/features/details/presentation/widgets/episode_picker_sheet.dart',
      ];
      for (final path in sheets) {
        final code = _code(path);
        expect(
          code,
          isNot(contains('ShaderMask')),
          reason: '$path is a scrolling list behind a BackdropFilter already',
        );
      }
    });
  });

  test('neither source sheet keeps a private copy of the chrome', () {
    const sheets = [
      'lib/features/sources/presentation/plugin_sources_sheet.dart',
      'lib/features/addons/presentation/addon_sources_sheet.dart',
    ];
    for (final path in sheets) {
      final code = _code(path);
      for (final type in const [
        '_GlassPalette',
        '_QualityBadge',
        '_DpadSourceButton',
      ]) {
        expect(
          code,
          isNot(contains('class $type')),
          reason:
              '$path re-declared $type; it lives in source_sheet_widgets.dart '
              'so that a fix to one sheet is a fix to both',
        );
      }
    }
  });
}

/// Executable lines only: a comment is allowed to name what was removed.
String _code(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: 'run this from the package root');
  return file
      .readAsLinesSync()
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');
}

Future<void> _pumpSheet(
  WidgetTester tester, {
  Brightness brightness = Brightness.dark,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        nuvioStreamServiceProvider.overrideWithValue(_FakeNuvioService()),
        linkProbeServiceProvider.overrideWithValue(_FakeProbeService()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(brightness: brightness),
        home: PluginSourcesSheet(target: _target),
      ),
    ),
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

final MultimediaItem _target = MultimediaItem(
  title: 'Test Movie',
  url: '',
  posterUrl: '',
  tmdbId: 1234,
);

class _FakeNuvioService implements NuvioStreamService {
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
          scraperId: 'alpha',
          scraperName: 'alpha',
          title: 'Movie ALPHA',
          url: 'https://cdn.test/alpha.mkv',
          quality: '1080p',
        ),
      ],
      completedCount: 1,
      totalCount: 1,
    );
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Every link answers "reachable" straight away, so the list settles.
class _FakeProbeService implements LinkProbeService {
  @override
  Future<LinkProbeResult> probe(
    String url, {
    Map<String, String>? headers,
  }) async => const LinkProbeResult(reachable: true);

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
