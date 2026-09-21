@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart';

import 'fake_vlc_engine.dart';

/// Pictures of the side panel, for reviewing the glass and the strip by eye.
///
/// Tagged `golden` and excluded from the default run (see dart_test.yaml), for
/// the reason search_desktop_golden_test.dart gives: text renders in the test
/// font, so a pixel diff here would fail for reasons that have nothing to do
/// with the layout. These are a drawing tool, not a regression gate — what the
/// panel must actually do is asserted in player_panel_test.dart.
///
///     flutter test --tags golden --update-goldens
///
/// The panel is drawn over a stand-in for the video rather than over black: it
/// is translucent now, and a picture of it on a black page cannot show whether
/// it is.
void main() {
  /// Bars of colour where the video would be. Deliberately garish — the point
  /// is to see how much of it comes through the glass and whether a row's
  /// label survives the brightest of it.
  Widget videoStandIn() => const DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[
          Color(0xFF1B6B7A),
          Color(0xFFE8D9A0),
          Color(0xFF6B2D5C),
          Color(0xFFF2F2F2),
        ],
        stops: <double>[0.0, 0.35, 0.7, 1.0],
      ),
    ),
    child: SizedBox.expand(),
  );

  List<StreamResult> sources() => const <StreamResult>[
    StreamResult(
      url: 'https://a.test/1',
      source: 'HubCloud [1080p] - Download 2.13 GB 👤 45',
      providerName: 'HubCloud',
    ),
    StreamResult(
      url: 'https://a.test/2',
      source: 'HubCloud [1080p] - Download 1.90 GB 👤 12',
      providerName: 'HubCloud',
    ),
    StreamResult(
      url: 'https://a.test/3',
      source: 'HubCloud [720p] - Download [FHD] 1.10 GB',
      providerName: 'HubCloud',
    ),
    StreamResult(
      url: 'https://a.test/4',
      source: 'HubCloud [720p] - Download [FHD] 980 MB',
      providerName: 'HubCloud',
    ),
    StreamResult(
      url: 'https://a.test/5',
      source: 'HubCloud [480p] - Download [SD] 610 MB',
      providerName: 'HubCloud',
    ),
  ];

  Future<void> draw(
    WidgetTester tester,
    String name, {
    required Size size,
    required bool isTv,
    PlayerPanelTab tab = PlayerPanelTab.sources,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final fake = FakeVlcEngine();
    fake.install();
    addTearDown(fake.dispose);
    final VlcPlayerController controller = await fake.attach();
    addTearDown(controller.dispose);

    final data = ValueNotifier<PanelData>(
      PanelData(
        sources: sources(),
        currentSourceIndex: 0,
        episodes: const <Episode>[],
      ),
    );
    addTearDown(data.dispose);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            videoStandIn(),
            // The panel's own barrier is the route's; drawn directly there is
            // none, so the scrim it normally sits over is painted here.
            const ColoredBox(color: Color(0x73000000)),
            PlayerPanel(
              controller: controller,
              initialTab: tab,
              data: data,
              isTv: isTv,
              onClose: () {},
              onPickSource: (_) {},
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/$name.png'),
    );
  }

  testWidgets('sources on a phone held upright', (tester) async {
    await draw(
      tester,
      'panel_phone_sources',
      size: const Size(390, 844),
      isTv: false,
    );
  });

  testWidgets('sources on a television', (tester) async {
    await draw(
      tester,
      'panel_tv_sources',
      size: const Size(960, 540),
      isTv: true,
    );
  });

  testWidgets('subtitles on a phone, for the tab strip', (tester) async {
    await draw(
      tester,
      'panel_phone_subtitles',
      size: const Size(390, 844),
      isTv: false,
      tab: PlayerPanelTab.subtitles,
    );
  });
}
