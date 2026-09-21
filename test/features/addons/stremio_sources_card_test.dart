import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/data/addon_repository.dart';
import 'package:skystream/core/addons/models/addon_manifest.dart';
import 'package:skystream/core/theme/app_theme.dart';
import 'package:skystream/features/addons/presentation/widgets/stremio_sources_card.dart';
import 'package:skystream/features/details/presentation/widgets/source_section_card.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

class _Repo extends AddonRepository {
  _Repo(this.count);
  final int count;
  @override
  AddonsState build() => AddonsState(
    isLoading: false,
    addons: [
      for (var i = 0; i < count; i++)
        ManagedAddon(
          manifestUrl: 'https://a$i/manifest.json',
          addedAt: DateTime(2026),
          manifest: AddonManifest(
            id: 'a$i',
            name: 'Addon $i',
            version: '1',
            resources: const [AddonResource(name: 'stream')],
            types: const ['movie'],
          ),
        ),
    ],
  );
}

Widget _app(Widget child, int addons) => ProviderScope(
  overrides: [addonRepositoryProvider.overrideWith(() => _Repo(addons))],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: AppTheme.createDarkTheme(null),
    home: Scaffold(body: SizedBox(width: 1200, child: child)),
  ),
);

/// The card that replaced the "Play from add-ons" button.
///
/// The label is the point. It used to promise playback for a tap that opens a
/// list of links, and on a series it named an episode - which the replacement
/// still does, because the card really is a shortcut to one episode and the
/// list further down the page is how any other is reached.
///
/// Naming that episode is where this earns its keep: gen-l10n emits
/// `stremioSearchAddonsForEpisode(int season, int episode)` positionally, both
/// arguments are ints, and passing them the wrong way round compiles cleanly
/// and renders the numbers swapped. Only a rendered assertion catches it.
void main() {
  testWidgets('labels name what the tap will actually do', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final (compact, ep, want)
        in <(bool, ({int season, int episode})?, String)>[
          (false, null, 'Search Stremio add-ons'),
          (true, (season: 2, episode: 5), 'Search add-ons: S2 E5'),
        ]) {
      await tester.pumpWidget(
        _app(
          StremioSourcesCard(compact: compact, episode: ep, onOpen: () {}),
          3,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(want), findsOneWidget, reason: 'label for $ep');
      expect(find.text('3 add-ons'), findsOneWidget);
      final btn = tester.getRect(find.byType(AnimatedContainer).first);
      // Full bleed on a phone; capped on a desktop, where the hero column can
      // run past a thousand points.
      if (compact) {
        expect(btn.width, kSourceActionDesktopWidth);
      } else {
        expect(btn.width, greaterThan(kSourceActionDesktopWidth));
      }
    }
  });

  testWidgets('hidden when no add-on serves streams', (tester) async {
    await tester.pumpWidget(_app(StremioSourcesCard(onOpen: () {}), 0));
    await tester.pumpAndSettle();
    expect(find.byType(SourceSectionCard), findsNothing);
  });
}
