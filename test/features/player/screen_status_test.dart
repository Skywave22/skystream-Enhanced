import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/services/download_service.dart';
import 'package:skystream/features/player/presentation/vlc/ended_card.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_controls.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_screen.dart';
import 'package:skystream/features/player/presentation/widgets/player_control_components.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import 'vlc_screen_harness.dart';

/// What the screen says while the engine is not showing a picture.
///
/// Every case here used to be silent: a failover's reason was overwritten by
/// the source name in the same synchronous run, an advance left the outgoing
/// episode's last frame up under a play glyph for the whole resolve, a dropped
/// live feed did the same for its two-second wait, and the stall watchdog's
/// first rung did its work without a word. Each one read as a hang.
void main() {
  setUp(installEngineMocks);
  tearDown(removeEngineMocks);

  Future<AppLocalizations> english() =>
      AppLocalizations.delegate.load(const Locale('en'));

  testWidgets(
    'a failover says why the last source was given up on',
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
      final l10n = await english();

      // The first source dies before it ever plays.
      await sendEvent(tester, snapshot(state: 'error'));
      await settle(tester);

      expect(find.textContaining(l10n.sourceAttempt(2, 2)), findsOneWidget);
      expect(
        find.text('Alpha · 1080p · ${l10n.playerReasonPlaybackError}'),
        findsOneWidget,
        reason:
            'the reason names the source it belongs to: the line above it now '
            'names the next one, and "playback error" alone says nothing '
            'about which',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  /// A two-episode series playing its first, with the disk lookup that opens
  /// every advance held shut so the screen can be looked at mid-advance.
  ///
  /// Hands back a getter: the service is built the first time the advance
  /// reads it, which is after this returns.
  Future<GatedDownloads Function()> pumpShow(WidgetTester tester) async {
    final first = Episode(
      name: 'One',
      url: 'https://example.com/e1.mp4',
      season: 1,
      episode: 1,
    );
    final second = Episode(
      name: 'Two',
      url: 'https://example.com/e2.mp4',
      season: 1,
      episode: 2,
    );
    final show = MultimediaItem(
      title: 'Show',
      url: 'https://example.com/show',
      posterUrl: '',
      contentType: MultimediaContentType.series,
      episodes: [first, second],
      provider: 'Remote',
    );
    late GatedDownloads downloads;
    await pumpPlayer(
      tester,
      item: show,
      episode: first,
      videoUrl: first.url,
      overrides: [
        downloadServiceProvider.overrideWith(
          (ref) => downloads = GatedDownloads(ref),
        ),
      ],
    );
    await sendFirstFrame(tester);
    expect(find.byKey(openingOverlayKey), findsNothing);
    expect(find.byType(VlcPlayerControls), findsOneWidget);
    return () => downloads;
  }

  testWidgets(
    'advancing covers the outgoing episode while the next one resolves',
    variant: texturePlatform,
    (tester) async {
      final downloads = await pumpShow(tester);
      final l10n = await english();

      // A minute from the end and then end of media. The near-end position
      // is load-bearing: an ending with no numbers behind it is a truncated
      // stream, and the screen fails such a source over rather than
      // advancing on it.
      await sendEvent(tester, snapshot(position: 1199000, duration: 1200000));
      await sendEvent(tester, snapshot(state: 'ended'));

      expect(
        find.byKey(openingOverlayKey),
        findsOneWidget,
        reason:
            'the outgoing episode\'s last frame under a play glyph, for as '
            'long as the next one takes to resolve, is the bug',
      );
      expect(find.byType(VlcPlayerControls), findsNothing);
      expect(find.text(l10n.loading), findsOneWidget);

      downloads().gate.complete();
      await settle(tester);

      expect(
        find.textContaining(l10n.sourceAttempt(1, 1)),
        findsOneWidget,
        reason: 'the chain went on to open the next episode',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Next while playing is not undone by the episode being left',
    variant: texturePlatform,
    (tester) async {
      final downloads = await pumpShow(tester);
      final l10n = await english();

      // Pressed through the widget rather than tapped. How the button is
      // activated is controls_focus_test's to hold; what is under test here
      // is what the screen does when it is.
      tester
          .widget<PlayerIconButton>(
            find.ancestor(
              of: find.byIcon(Icons.skip_next_rounded),
              matching: find.byType(PlayerIconButton),
            ),
          )
          .onPressed!();
      await tester.pump();
      expect(find.byKey(openingOverlayKey), findsOneWidget);

      // The outgoing engine has not been told to stop and is still ticking.
      await sendEvent(tester, snapshot(position: 3000));

      expect(
        find.byKey(openingOverlayKey),
        findsOneWidget,
        reason:
            'a tick from the episode being left is not the next episode\'s '
            'first frame; taken for one, the overlay came off and the chrome '
            'remounted over a picture about to be replaced',
      );

      downloads().gate.complete();
      await settle(tester);
      expect(find.textContaining(l10n.sourceAttempt(1, 1)), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'the reconnecting line clears when the viewer pauses mid-stall',
    variant: texturePlatform,
    (tester) async {
      await pumpPlayer(tester);
      await sendFirstFrame(tester);
      final l10n = await english();

      // Silence: no more ticks. The watchdog nudges at ten seconds and puts
      // up the line.
      for (var i = 0; i < 11; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.text(l10n.playerReconnecting), findsOneWidget);

      // Pausing ends the episode of recovery; the line must go with it,
      // rather than waiting for a first frame that a paused player never
      // produces.
      await sendEvent(tester, snapshot(state: 'paused', position: 1500));
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.text(l10n.playerReconnecting),
        findsNothing,
        reason: 'the stall ended when the viewer paused',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a dropped live feed says it is reconnecting while it waits',
    variant: texturePlatform,
    (tester) async {
      final channel = MultimediaItem(
        title: 'News',
        url: 'https://example.com/live.m3u8',
        posterUrl: '',
        contentType: MultimediaContentType.livestream,
        provider: 'Remote',
      );
      await pumpPlayer(tester, item: channel, videoUrl: channel.url);
      await sendFirstFrame(tester);
      expect(find.byKey(openingOverlayKey), findsNothing);
      final l10n = await english();

      await sendEvent(tester, snapshot(state: 'ended'));

      expect(
        find.byKey(openingOverlayKey),
        findsOneWidget,
        reason:
            'the wait before the reopen is spent on the overlay, not on '
            'the last frame the feed produced',
      );
      expect(find.text(l10n.playerReconnecting), findsOneWidget);
      expect(
        find.byKey(endedCardKey),
        findsNothing,
        reason:
            'a live feed has no end. Reaching one means the stream dropped, '
            'and "you have finished" over a channel that is coming back is '
            'the one thing the ended card must never say',
      );

      // The reopen delay, then the open itself.
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);

      expect(
        find.textContaining(l10n.sourceAttempt(1, 1)),
        findsOneWidget,
        reason: 'the feed was reopened',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a stall says it is reconnecting until the position moves',
    variant: texturePlatform,
    (tester) async {
      await pumpPlayer(tester);
      await sendFirstFrame(tester);
      final l10n = await english();
      expect(find.text(l10n.playerReconnecting), findsNothing);

      // Past the watchdog's first rung with the position frozen.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(seconds: 1));
      }

      expect(
        find.text(l10n.playerReconnecting),
        findsOneWidget,
        reason:
            'the nudge is otherwise silent: a frozen frame with nothing said '
            'for up to 25 seconds',
      );

      await sendEvent(tester, snapshot(position: 2500));

      expect(
        find.text(l10n.playerReconnecting),
        findsNothing,
        reason: 'the pill must not outlive the recovery it describes',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );
}
