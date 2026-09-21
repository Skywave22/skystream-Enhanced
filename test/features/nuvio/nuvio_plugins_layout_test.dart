import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/nuvio/data/nuvio_repository.dart';
import 'package:skystream/core/nuvio/models/nuvio_models.dart';
import 'package:skystream/core/theme/app_theme.dart';
import 'package:skystream/features/nuvio/presentation/nuvio_plugins_view.dart';
import 'package:skystream/shared/widgets/custom_widgets.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

class _Repo extends NuvioRepository {
  @override
  NuvioState build() => NuvioState(
    isLoading: false,
    repos: [
      NuvioRepo(
        manifestUrl: 'https://yoru/manifest.json',
        addedAt: DateTime(2026),
        manifest: const NuvioManifest(
          name: "Yoru's Repo",
          version: '1.0.0',
          scrapers: [
            NuvioScraperInfo(id: 's1', name: 'S1', version: '1', filename: 'f'),
          ],
        ),
      ),
    ],
  );
}

/// Two alignments on the Nuvio plugins screen that are easy to break and hard
/// to notice.
///
/// The repository actions belong at the END of their row, primary furthest
/// right - a Wrap defaults to `start`, so this is one property away from
/// regressing.
///
/// The version badge and the expansion chevron share a centre. They did not:
/// an ExpansionTile centres its trailing chevron on the WHOLE title block -
/// title plus the line beneath it - while anything in `title` sits on the
/// title's own line, so a badge placed there missed the chevron by about half
/// the subtitle's height.
void main() {
  testWidgets('actions are flush right and the badge meets the chevron', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [nuvioRepositoryProvider.overrideWith(_Repo.new)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.createDarkTheme(null),
          home: const Scaffold(body: NuvioPluginsView()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final add = tester.getRect(find.text('Add Repository'));
    final check = tester.getRect(find.text('Check Updates'));
    final badge = tester.getRect(find.text('v1.0.0'));
    final chevron = tester.getRect(find.byIcon(Icons.expand_more_rounded));
    debugPrint(
      'L add=[${add.left.toStringAsFixed(0)},${add.right.toStringAsFixed(0)}] '
      'check=[${check.left.toStringAsFixed(0)},${check.right.toStringAsFixed(0)}]',
    );
    debugPrint(
      'L badgeCy=${badge.center.dy.toStringAsFixed(1)} '
      'chevronCy=${chevron.center.dy.toStringAsFixed(1)}',
    );
    // The row they sit in, so "right-aligned" can be measured rather than
    // eyeballed.
    // Measured against the CARD's content width, not the Wrap's. A Wrap
    // shrink-wraps to its children, so "flush with the Wrap" is true even
    // when the whole group is sitting at the far left - which is exactly how
    // a first attempt at this passed while the buttons were 817 dp short of
    // the edge. The divider spans the content, so it is the honest reference.
    final content = tester.getRect(find.byType(Divider).first);
    final addBtn = tester.getRect(
      find
          .ancestor(
            of: find.text('Add Repository'),
            matching: find.byType(CustomButton),
          )
          .first,
    );
    debugPrint(
      'L content=[${content.left.toStringAsFixed(0)},'
      '${content.right.toStringAsFixed(0)}] '
      'addBtnRight=${addBtn.right.toStringAsFixed(1)}',
    );
    expect(
      content.right - addBtn.right,
      moreOrLessEquals(0, epsilon: 0.5),
      reason: 'the primary action must be flush with the card, not the Wrap',
    );
    expect(
      check.right,
      lessThan(add.left),
      reason: 'Check Updates sits left of Add Repository',
    );
    expect(
      badge.center.dy,
      moreOrLessEquals(chevron.center.dy, epsilon: 0.6),
      reason: 'the version badge and the chevron share a centre',
    );
  });
}
