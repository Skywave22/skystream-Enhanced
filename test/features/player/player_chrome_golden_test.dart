@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel.dart'
    show PlayerPanelTab;
import 'package:skystream/features/player/presentation/vlc/resume_hint.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_controls.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart';

import 'fake_vlc_engine.dart';

/// Pictures of the bottom bar, for reviewing its shape by eye.
///
/// Tagged `golden` and excluded from the default run, for the reason
/// search_desktop_golden_test.dart gives: text renders in the test font, so a
/// pixel diff would fail for reasons that have nothing to do with the layout.
/// A drawing tool, not a regression gate — what the bar must actually contain
/// is asserted in controls_focus_test.dart.
///
///     flutter test --run-skipped --tags golden --update-goldens \
///       test/features/player/player_chrome_golden_test.dart
///
/// The two are drawn side by side on purpose: the desktop bar is the one that
/// dropped its seek pair and took the clock down off the scrubber, and the
/// only way to see that it is still balanced is against the bar that did not.
void main() {
  Future<void> draw(
    WidgetTester tester,
    String name, {
    required bool isTv,
    required bool desktop,
    required Size size,
    bool resumeHint = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final fake = FakeVlcEngine();
    fake.install();
    addTearDown(fake.dispose);
    final VlcPlayerController controller = await fake.attach();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceProfileProvider.overrideWithValue(
            AsyncValue.data(DeviceProfile(isTv: isTv)),
          ),
          playerSettingsProvider.overrideWithBuild(
            (_, _) => const PlayerSettings(),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                // Something behind the scrim, so the bar's gradient is
                // visible as a gradient rather than as black on black.
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[Color(0xFF14323C), Color(0xFFD8C79A)],
                    ),
                  ),
                  child: SizedBox.expand(),
                ),
                VlcPlayerControls(
                  controller: controller,
                  title: 'The Body',
                  subtitle: 'S5 E16',
                  onBack: () {},
                  onNextEpisode: () {},
                  onPreviousEpisode: () {},
                  onOpenPanel: (_) async {},
                  panelTabs: const <PlayerPanelTab>{
                    PlayerPanelTab.sources,
                    PlayerPanelTab.audio,
                    PlayerPanelTab.subtitles,
                    PlayerPanelTab.episodes,
                  },
                  onToggleFullscreen: desktop ? () {} : null,
                ),
                // A sibling of the controls, which is how the screen mounts
                // it: the hint is anchored off the chrome token rather than
                // off anything it can see.
                if (resumeHint)
                  ResumeHint(
                    position: const Duration(minutes: 8, seconds: 50),
                    isTv: isTv,
                    onStartOver: () {},
                    onDismissed: () {},
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // A playing snapshot a minute in, so the clock has something to read and
    // the play/pause glyph is the pause one.
    await fake.emit(<String, Object?>{
      'state': 'playing',
      'position': 65000,
      'duration': 300000,
      'isSeekable': true,
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/$name.png'),
    );

    // Leave the controller paused: a playing one holds the stall watchdog,
    // and flutter_test checks for pending timers before tear-down.
    await fake.emit(<String, Object?>{'state': 'paused', 'position': 65000});
    await tester.pump();
  }

  testWidgets('the desktop bar', (tester) async {
    await draw(
      tester,
      'chrome_desktop',
      isTv: false,
      desktop: true,
      size: const Size(1280, 720),
    );
  });

  testWidgets('a narrow desktop window, with the resume hint up', (
    tester,
  ) async {
    // The frame the reported screenshot was taken on: a small desktop window
    // where the utility row used to wrap onto five runs, stand 284 dp tall
    // inside a 330 dp viewport, and take the scrubber off the top of its own
    // chrome with the resume hint sitting on top of what was left.
    await draw(
      tester,
      'chrome_desktop_narrow',
      isTv: false,
      desktop: true,
      size: const Size(440, 330),
      resumeHint: true,
    );
  });

  testWidgets('a handset held upright', (tester) async {
    // The transport is in the middle of the frame here, so the bar's left end
    // is the episode pair and the clock and the utility strip gets the rest.
    await draw(
      tester,
      'chrome_phone',
      isTv: false,
      desktop: false,
      size: const Size(390, 844),
      resumeHint: true,
    );
  });

  testWidgets('the television bar, which keeps its seek pair', (tester) async {
    await draw(
      tester,
      'chrome_tv',
      isTv: true,
      desktop: false,
      size: const Size(1280, 720),
    );
  });
}
