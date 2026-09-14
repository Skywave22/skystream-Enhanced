import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/core/storage/history_repository.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_controls.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_screen.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart';

import 'vlc_screen_harness.dart';

/// The startup gap this file exists for.
///
/// `setMedia` does no network work: it hands libVLC a URL and returns, so the
/// screen can reach the playing stage while the engine has opened nothing and
/// `VlcPlayer` is showing an empty surface - many seconds on a cold source,
/// forever on a dead one. The video widget has to stay mounted through that
/// (nothing attaches otherwise), so an opaque overlay above it covers the gap.
void main() {
  setUp(installEngineMocks);
  tearDown(removeEngineMocks);

  group('the opening overlay', () {
    testWidgets(
      'covers the video until the first frame lands',
      variant: texturePlatform,
      (tester) async {
        await pumpPlayer(tester);

        expect(
          find.byType(VlcPlayer),
          findsOneWidget,
          reason: 'the video has to stay mounted or the engine never attaches',
        );
        final overlay = find.byKey(openingOverlayKey);
        expect(
          overlay,
          findsOneWidget,
          reason: 'setMedia has returned but no frame exists yet',
        );
        expect(
          tester.getSize(overlay),
          tvSize,
          reason: 'a gap the viewer can see through is the gap itself',
        );
        expect(
          (tester.widget<ColoredBox>(
            find.descendant(
              of: overlay,
              matching: find.byType(ColoredBox),
              matchRoot: true,
            ),
          )).color.a,
          1.0,
          reason: 'opaque, and by a plain colour rather than an effect layer',
        );
        expect(
          find.byType(VlcPlayerControls),
          findsNothing,
          reason: 'a seek bar over a black rectangle is the bug',
        );

        await sendFirstFrame(tester);

        expect(find.byKey(openingOverlayKey), findsNothing);
        expect(
          find.byType(VlcPlayerControls),
          findsOneWidget,
          reason:
              'the chrome takes over the moment there is a picture behind it',
        );

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'a long source name never pushes the probe badge off a narrow screen',
      variant: texturePlatform,
      (tester) async {
        // A source name capped at a fixed width, plus the icon and the gaps,
        // leaves no room for the badge on a 320px phone and the Row overflows.
        // The name is Flexible instead.
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final longName = 'Provider ' * 40; // ~360 chars, wider than any phone
        final streams = [
          StreamResult(url: 'https://a.example/1.m3u8', source: longName),
          StreamResult(url: 'https://b.example/2.m3u8', source: longName),
        ];

        // Its own tree rather than pumpPlayer: the probe list only exists
        // while the race is running, and the frames that lay it out have to
        // be looked at one at a time.
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              deviceProfileProvider.overrideWithValue(
                const AsyncValue.data(DeviceProfile(isTv: false)),
              ),
              playerSettingsProvider.overrideWithBuild(
                (_, _) => const PlayerSettings(),
              ),
              activeProviderProvider.overrideWithValue(null),
              historyRepositoryProvider.overrideWithValue(NoHistory()),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: VlcPlayerScreen(
                item: MultimediaItem(
                  title: 'Channel One',
                  url: 'https://example.com/movie.mp4',
                  posterUrl: '',
                ),
                videoUrl: 'https://example.com/movie.mp4',
                preloadedStreams: streams,
              ),
            ),
          ),
        );

        // Every probe icon is one of these three.
        var sawRows = false;
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          expect(tester.takeException(), isNull);
          if (find.byIcon(Icons.more_horiz_rounded).evaluate().isNotEmpty ||
              find.byIcon(Icons.check_rounded).evaluate().isNotEmpty ||
              find.byIcon(Icons.close_rounded).evaluate().isNotEmpty) {
            sawRows = true;
          }
        }
        expect(
          sawRows,
          isTrue,
          reason:
              'the probe rows must have been laid out at 320px, or this '
              'test proves nothing',
        );

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('names the source being opened', variant: texturePlatform, (
      tester,
    ) async {
      await pumpPlayer(tester);

      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(
        find.textContaining(l10n.sourceAttempt(1, 1)),
        findsOneWidget,
        reason: 'nine sources failing over must not look like one hanging',
      );

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'skip abandons the source and advances the failover ring',
      variant: texturePlatform,
      (tester) async {
        await pumpPlayer(
          tester,
          // Bare paths, so the resolver's health probe answers without a socket.
          preloadedStreams: [
            const StreamResult(
              url: '/sources/alpha.mkv',
              source: '1080p',
              providerName: 'Alpha',
            ),
            const StreamResult(
              url: '/sources/beta.mkv',
              source: '720p',
              providerName: 'Beta',
            ),
          ],
        );

        final l10n = await AppLocalizations.delegate.load(const Locale('en'));
        expect(find.textContaining(l10n.sourceAttempt(1, 2)), findsOneWidget);

        await tester.tap(find.text(l10n.playerSkipSource));
        await settle(tester);

        expect(
          find.textContaining(l10n.sourceAttempt(2, 2)),
          findsOneWidget,
          reason: 'skip hands the source to the failover ring, which moves on',
        );
        expect(
          find.byKey(openingOverlayKey),
          findsOneWidget,
          reason: 'the next source has not produced a frame either',
        );

        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}
