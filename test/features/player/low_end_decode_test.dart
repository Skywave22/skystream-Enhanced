/// The weakest device in the support window, and the two things the player
/// now does about it.
///
/// minSdk 24 is 2016 hardware. A television box of that vintage handed the 4K
/// rendition of an HLS stream has no MediaCodec profile for it, falls back to
/// avcodec, and produces a slideshow with perfect audio. Every signal the
/// screen had before this reads that as healthy playback: audio drives
/// libVLC's clock, so the position advances, the state stays `playing`, the
/// stall watchdog never fires, and watch progress is recorded for a film
/// nobody could see.
///
/// Two defences, tested here end to end because both are wiring - the
/// arithmetic behind them is proved in playback_recovery_test.dart:
///  * a ceiling on the adaptive ladder, so the rendition is not handed over in
///    the first place;
///  * a video-presence probe over `getMediaStats`, which is implemented on all
///    five backends and, before this, called by nothing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import 'fake_vlc_engine.dart';
import 'vlc_screen_harness.dart';

void main() {
  late FakeVlcEngine engine;

  /// Where the position clock has got to. Kept across calls to [playSeconds]
  /// because an unmoving position is a stall, and a stall hands the second to
  /// the other watchdog - which is the whole point of the separation and would
  /// silently make every test here about the wrong mechanism.
  var positionMs = 0;

  setUp(() {
    positionMs = 4000;
    engine = FakeVlcEngine();
    installEngineMocks(engine: engine);
  });
  tearDown(removeEngineMocks);

  Future<AppLocalizations> english() =>
      AppLocalizations.delegate.load(const Locale('en'));

  /// A 4K television panel, at the density such a panel is reported with, so
  /// the logical layout stays the harness's 960x540 ten-foot budget while the
  /// physical surface is a real 3840x2160.
  const Size uhdPanel = Size(3840, 2160);
  const double uhdDensity = 4;

  /// Bare paths, so the resolver's health probe answers without a socket.
  const twoSources = <StreamResult>[
    StreamResult(url: '/sources/alpha.m3u8', source: '4K', providerName: 'A'),
    StreamResult(url: '/sources/beta.m3u8', source: '1080p', providerName: 'B'),
  ];

  /// The instance options the engine was actually created with.
  List<String> createdOptions() {
    final create = engine.callsTo('create').single;
    final arguments = create.arguments as Map<Object?, Object?>;
    return (arguments['options'] as List<Object?>).cast<String>();
  }

  /// The per-media options of the last `setSource` - what `setMedia` becomes
  /// on the wire.
  List<String> lastMediaOptions() {
    final calls = engine.callsTo('setSource');
    final arguments = calls.last.arguments as Map<Object?, Object?>;
    return (arguments['mediaOptions'] as List<Object?>? ?? <Object?>[])
        .cast<String>();
  }

  /// Drives [seconds] of playback that the screen has every reason to call
  /// healthy: the position advances a second per second, so the stall watchdog
  /// stays silent and the video-presence probe is the only thing looking.
  ///
  /// One watchdog tick per iteration, with the position moving inside it. The
  /// snapshot carries a decoded size because that is how the screen knows
  /// there is a picture to expect at all - and it is exactly what the failing
  /// device reports, since the size comes from the media's track info rather
  /// than from a video output that opened.
  Future<void> playSeconds(WidgetTester tester, int seconds) async {
    for (var i = 0; i < seconds; i++) {
      positionMs += 1000;
      await sendSnapshot(tester, <String, Object?>{
        ...snapshot(position: positionMs, duration: 7200000),
        'videoSize': <String, Object?>{'width': 3840, 'height': 2160},
      });
      // Past the controller's 250 ms event throttle, so the position lands and
      // the screen counts it as progress...
      await tester.pump(const Duration(milliseconds: 300));
      // ...and out to a full second, which is one watchdog tick.
      await tester.pump(const Duration(milliseconds: 700));
    }
  }

  group('the adaptive ladder is given a ceiling', () {
    // The headline case. `adaptiveLogic: highest` with no ceiling is what
    // handed a 2016 box the 4K rung of every stream it opened, and the config
    // has carried `adaptiveMaxHeight` all along with no call site anywhere in
    // lib/.
    testWidgets(
      'a device not known to cope is capped below 4K',
      variant: texturePlatform,
      (tester) async {
        await pumpPlayer(
          tester,
          preloadedStreams: twoSources,
          profile: const DeviceProfile(isTv: true, physicalRamMb: 2048),
          panelPhysicalSize: uhdPanel,
          panelDevicePixelRatio: uhdDensity,
        );

        expect(
          createdOptions(),
          contains('--adaptive-maxheight=1080'),
          reason:
              'a standard-tier television box behind a 4K panel must not be '
              'offered the rung it has no hardware decoder for',
        );

        await tester.pumpWidget(const SizedBox());
      },
    );

    // The other half of the same rule, and the reason the cap is a device
    // question rather than a blanket 1080p: the same panel, a device that can
    // be shown to manage it, and the top rung is still on offer.
    testWidgets(
      'a capable device keeps the top rung',
      variant: texturePlatform,
      (tester) async {
        await pumpPlayer(
          tester,
          preloadedStreams: twoSources,
          profile: const DeviceProfile(
            isTv: true,
            physicalRamMb: 8192,
            tier: DeviceTier.high,
          ),
          panelPhysicalSize: uhdPanel,
          panelDevicePixelRatio: uhdDensity,
        );

        expect(createdOptions(), contains('--adaptive-maxheight=2160'));

        await tester.pumpWidget(const SizedBox());
      },
    );

    // Nothing is asked for that the panel cannot show, capable or not. A
    // 1080p television is the commonest device in the support window and 4K
    // on it is pure waste - four times the bandwidth for a picture that is
    // downscaled before it is drawn.
    testWidgets(
      'nobody is asked for more than the panel shows',
      variant: texturePlatform,
      (tester) async {
        await pumpPlayer(
          tester,
          preloadedStreams: twoSources,
          profile: const DeviceProfile(
            isTv: true,
            physicalRamMb: 8192,
            tier: DeviceTier.high,
          ),
          panelPhysicalSize: const Size(1920, 1080),
          panelDevicePixelRatio: 2,
        );

        expect(createdOptions(), contains('--adaptive-maxheight=1080'));

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('video presence behind an advancing clock', () {
    // The vout that never opened: a pixel-buffer pool that could not be
    // allocated on a low-memory device, or a platform that refused the
    // output. Audio plays, the position advances, `videoSize` is populated
    // from track info, and the viewer has a black rectangle with a seek bar
    // over it. Nothing in the app could tell this from playback.
    testWidgets(
      'a clock advancing over no picture is not playback',
      variant: texturePlatform,
      (tester) async {
        await pumpPlayer(tester, preloadedStreams: twoSources);
        final l10n = await english();
        engine.decodedPictures(displayed: 0, lost: 0);

        final opensBefore = engine.callsTo('setSource').length;
        // Stopped the moment the source is given up on, because the line that
        // says why is cleared by the next picture - and this loop is feeding
        // the screen a position every second.
        var opens = opensBefore;
        for (var i = 0; i < 16 && opens == opensBefore; i++) {
          await playSeconds(tester, 1);
          opens = engine.callsTo('setSource').length;
        }
        await settle(tester);

        expect(
          opens,
          greaterThan(opensBefore),
          reason:
              'a source that produces sound and no picture has to be given '
              'up on, not recorded as watched',
        );
        expect(
          find.text(l10n.playerReasonSourceNeverStarted),
          findsOneWidget,
          reason: 'and the viewer has to be told why the picture went away',
        );

        await tester.pumpWidget(const SizedBox());
      },
    );

    // The slideshow. Pictures do reach the screen, a handful a second, while
    // the decoder throws away everything that arrives late - which is what
    // `--drop-late-frames` does, and it is why the clock stays perfect. The
    // answer is not the failover ladder: the source is fine and its mirrors
    // will be decoded by the same silicon. It is to ask for less of it.
    testWidgets(
      'a decoder that cannot keep up is asked for one rung less',
      variant: texturePlatform,
      (tester) async {
        await pumpPlayer(
          tester,
          preloadedStreams: twoSources,
          profile: const DeviceProfile(
            isTv: true,
            physicalRamMb: 8192,
            tier: DeviceTier.high,
          ),
          panelPhysicalSize: uhdPanel,
          panelDevicePixelRatio: uhdDensity,
        );
        expect(createdOptions(), contains('--adaptive-maxheight=2160'));

        // Two frames a second displayed against everything else dropped.
        var displayed = 0;
        var lost = 0;
        for (var i = 0; i < 12; i++) {
          displayed += 2;
          lost += 22;
          engine.decodedPictures(displayed: displayed, lost: lost);
          await playSeconds(tester, 1);
        }

        expect(
          lastMediaOptions(),
          contains(':adaptive-maxheight=1440'),
          reason:
              'the ceiling is fixed on the engine instance, so a step down has '
              'to ride on the media that is reopened',
        );

        await tester.pumpWidget(const SizedBox());
      },
    );

    // The guard that keeps every other screen test honest, and the difference
    // between a probe and a hair trigger: `getMediaStats` answers on all five
    // backends and some of them answer nothing. Zeroes from an engine that
    // never claimed to have numbers must not read as a missing picture.
    testWidgets(
      'an engine with no counters is left alone',
      variant: texturePlatform,
      (tester) async {
        await pumpPlayer(tester, preloadedStreams: twoSources);
        final l10n = await english();
        // mediaStats stays null: `available` is false and every counter is zero,
        // which is indistinguishable from a dead decoder if the flag is ignored.

        final opensBefore = engine.callsTo('setSource').length;
        await playSeconds(tester, 12);

        expect(engine.callsTo('setSource').length, opensBefore);
        expect(find.text(l10n.playerReasonSourceNeverStarted), findsNothing);

        await tester.pumpWidget(const SizedBox());
      },
    );

    // The stall watchdog and the presence probe answer opposite questions and
    // must never both speak for the same second. A frozen clock is the stall
    // watchdog's, and while it holds the floor the presence probe's window is
    // torn down rather than counting a freeze as a decode failure.
    testWidgets(
      'a frozen clock is the stall watchdog\'s, not this one\'s',
      variant: texturePlatform,
      (tester) async {
        await pumpPlayer(tester, preloadedStreams: twoSources);
        final l10n = await english();
        engine.decodedPictures(displayed: 0, lost: 0);

        // One frame, then nothing moves for long enough that the presence probe
        // would have convicted twice over if it were still counting.
        await playSeconds(tester, 1);
        for (var i = 0; i < 11; i++) {
          await tester.pump(const Duration(seconds: 1));
        }

        expect(
          find.text(l10n.playerReasonSourceNeverStarted),
          findsNothing,
          reason: 'a stalled source has not proved anything about this decoder',
        );
        expect(
          find.text(l10n.playerReconnecting),
          findsOneWidget,
          reason: 'and the stall ladder is the one that owns those seconds',
        );

        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}
