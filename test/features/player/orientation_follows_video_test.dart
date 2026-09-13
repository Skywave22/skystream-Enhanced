import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/features/player/presentation/player_platform_service.dart';
import 'package:skystream/features/player/presentation/widgets/player_control_components.dart'
    show PlayerBottomBar, PlayerIconButton;

import 'vlc_screen_harness.dart';

/// DEFECT 4 — the player's orientation follows the video, and only the video.
///
/// The owner's words: "auto set the player orientation, no need of
/// portrait/landscape switch, set the orientation based on video type." Four
/// separate things were wrong, and each of them is pinned below on the real
/// screen over the real engine channel rather than on the service alone:
///
///  1. **The shape was read off a measurement that has no idea which way up
///     the picture is.** `videoSize` is the elementary stream's declared width
///     and height on every backend — the rotation a phone camera writes sits
///     in a field next to it that nothing forwards — so a clip shot in
///     portrait reports 1920x1080 and would have turned the handset the wrong
///     way. The decision comes off `codedVideoSize` now: the buffer libVLC
///     decodes into, which is the upright picture because the rotation has
///     already been applied to it.
///  2. **The settle was a two-*event* rule.** It waited for two consecutive
///     matching snapshots, but the natives drop a snapshot identical to the
///     one before it and a paused engine sends none at all, so a player paused
///     on its first frame never settled. A shape now has to *hold* for
///     [PlayerPlatformService.shapeSettleDelay], which one reading can do.
///  3. `restoreOrientation` pinned `portraitUp` on the way out whether or not
///     anything had been pinned on the way in. A player closed before the
///     first frame decoded therefore froze rotation for the rest of the
///     process, since nothing else in the app calls `setPreferredOrientations`
///     at all.
///  4. A manual rotate button sat in the action strip, and pressing it latched
///     the automatic behaviour off for the rest of the session.
///
/// The pin is a *pair* — landscapeLeft and landscapeRight, portraitUp and
/// portraitDown — so the viewer can still turn the handset end for end; what
/// they cannot do any more is ask for the orientation the video is not.
void main() {
  late List<List<String>> pinned;

  setUp(() {
    installEngineMocks();
    pinned = <List<String>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'SystemChrome.setPreferredOrientations') {
            pinned.add(List<String>.from(call.arguments as List<Object?>));
          }
          return null;
        });
  });

  tearDown(() {
    removeEngineMocks();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  const landscape = <String>[
    'DeviceOrientation.landscapeLeft',
    'DeviceOrientation.landscapeRight',
  ];
  const portrait = <String>[
    'DeviceOrientation.portraitUp',
    'DeviceOrientation.portraitDown',
  ];

  /// A native snapshot carrying both sizes the engine reports, as the two
  /// Darwin plugins send them: `videoSize` off the media's video track and
  /// `codedSize` off the buffer the decoder is writing into.
  ///
  /// [position] moves so the controller treats each as a fresh tick.
  Map<String, Object?> event({
    required int position,
    Size? track,
    Size? buffer,
    String state = 'playing',
  }) => <String, Object?>{
    ...snapshot(position: position, state: state),
    if (track != null)
      'videoSize': <String, Object?>{
        'width': track.width.round(),
        'height': track.height.round(),
      },
    if (buffer != null)
      'codedSize': <String, Object?>{
        'width': buffer.width.round(),
        'height': buffer.height.round(),
      },
  };

  /// The ordinary case: the track and the buffer agree about which way up the
  /// picture is, and the buffer is the taller of the two because the decoder
  /// pads height to a multiple of sixteen.
  Map<String, Object?> upright(int width, int height, {required int position}) {
    final pad = (height + 15) ~/ 16 * 16;
    return event(
      position: position,
      track: Size(width.toDouble(), height.toDouble()),
      buffer: Size(width.toDouble(), pad.toDouble()),
    );
  }

  /// Lets the shape hold for as long as the settle asks, without the engine
  /// saying anything more.
  Future<void> waitOutSettle(WidgetTester tester) => tester.pump(
    PlayerPlatformService.shapeSettleDelay + const Duration(milliseconds: 1),
  );

  /// The screen on a handset: [PlayerFormFactor.phone] is the only profile the
  /// orientation policy acts on that also restores to a fixed orientation.
  Future<void> pumpPhone(WidgetTester tester) => pumpPlayer(
    tester,
    isTv: false,
    profile: const DeviceProfile(),
    panelPhysicalSize: const Size(1080, 1920),
    panelDevicePixelRatio: 3,
  );

  testWidgets('a landscape film settles the device landscape, once', (
    tester,
  ) async {
    await pumpPhone(tester);
    await settle(tester);
    pinned.clear();

    await sendEvent(tester, upright(1920, 1080, position: 1500));
    expect(
      pinned,
      isEmpty,
      reason:
          'the shape the engine has only just reported is a candidate, not a '
          'verdict: libVLC revises the track during startup, and acting on '
          'the first reading is what made the handset rotate twice',
    );

    await waitOutSettle(tester);
    expect(pinned, [landscape]);

    // The rest of the film, including a variant switch to a different
    // resolution of the same landscape picture. Same verdict, no more
    // messages, no more rotations.
    await sendEvent(tester, upright(1920, 1080, position: 3500));
    await sendEvent(tester, upright(1280, 720, position: 4500));
    await sendEvent(tester, upright(1280, 720, position: 5500));
    await waitOutSettle(tester);
    expect(pinned, [landscape]);

    await tester.pumpWidget(const SizedBox());
  }, variant: texturePlatform);

  testWidgets('a portrait clip settles the device portrait', (tester) async {
    await pumpPhone(tester);
    await settle(tester);
    pinned.clear();

    await sendEvent(tester, upright(1080, 1920, position: 1500));
    await waitOutSettle(tester);

    expect(pinned, [portrait]);

    await tester.pumpWidget(const SizedBox());
  }, variant: texturePlatform);

  testWidgets(
    'a clip shot in portrait on a phone turns the handset portrait, not '
    'landscape',
    (tester) async {
      await pumpPhone(tester);
      await settle(tester);
      pinned.clear();

      // What a handset camera actually writes, and what the engine actually
      // reports for it: landscape frames plus a 90-degree rotation matrix. The
      // media track therefore declares 1920x1080 - `libvlc_video_get_size`
      // reads `libvlc_media_get_tracks_info`, a struct with no orientation
      // member, and Android reads the same declared numbers off
      // `currentVideoTrack` - while the buffer libVLC decodes into is 1088x1920,
      // because `vmem.c` runs `video_format_ApplyRotation` before it hands the
      // format to the sink.
      //
      // Only one of those two is the picture the viewer sees.
      await sendEvent(
        tester,
        event(
          position: 1500,
          track: const Size(1920, 1080),
          buffer: const Size(1088, 1920),
        ),
      );
      await waitOutSettle(tester);

      expect(
        pinned,
        [portrait],
        reason:
            'the handset must turn the way the picture is, not the way the '
            'frames happen to be stored; rotating this one landscape is worse '
            'than the manual switch that was removed',
      );

      await tester.pumpWidget(const SizedBox());
    },
    variant: texturePlatform,
  );

  testWidgets('a backend that reports no rendered size pins nothing', (
    tester,
  ) async {
    await pumpPhone(tester);
    await settle(tester);
    pinned.clear();

    // Android's shipping path: an AndroidView platform view, which sends
    // `videoSize` and no `codedSize` at all. The one size it does send cannot
    // tell a landscape film from a portrait clip shot on a phone, so the
    // player declines to guess and leaves the device wherever the viewer's own
    // rotation setting has it.
    await sendEvent(
      tester,
      event(position: 1500, track: const Size(1920, 1080)),
    );
    await waitOutSettle(tester);
    await sendEvent(
      tester,
      event(position: 2500, track: const Size(1920, 1080)),
    );
    await waitOutSettle(tester);

    expect(
      pinned,
      isEmpty,
      reason:
          'a rotation-blind size is not evidence. Forwarding the track\'s '
          'orientation field from the plugin is what earns this platform the '
          'feature back',
    );

    await tester.pumpWidget(const SizedBox());
  }, variant: texturePlatform);

  testWidgets('a shape revised during startup turns the handset once', (
    tester,
  ) async {
    await pumpPhone(tester);
    await settle(tester);
    pinned.clear();

    // The reading the old code acted on immediately, replaced a tick later by
    // the one that sticks. Only the shape that stuck may reach the OS: the
    // viewer must not watch the device swing landscape and back.
    await sendEvent(tester, upright(1920, 1080, position: 1500));
    await sendEvent(tester, upright(1080, 1920, position: 2500));
    await waitOutSettle(tester);

    expect(pinned, [portrait]);

    await tester.pumpWidget(const SizedBox());
  }, variant: texturePlatform);

  testWidgets('a player paused on its first frame still settles', (
    tester,
  ) async {
    await pumpPhone(tester);
    await settle(tester);
    pinned.clear();

    // One snapshot, and then silence - which is not a contrived case. Every
    // native side drops a snapshot identical to the one before it, so a paused
    // engine, having said "paused, 1920x1080" once, has nothing further to
    // say. Nothing downstream covers for it either: the controller's own stall
    // clock, which does re-publish a stalled value while playback is running,
    // is explicitly inert while the state is paused.
    //
    // The rule this replaced counted EVENTS, so it sat waiting for a second
    // one that was never coming and left the handset unrotated for as long as
    // the viewer stayed paused.
    await sendEvent(
      tester,
      event(
        position: 1500,
        state: 'paused',
        track: const Size(1920, 1080),
        buffer: const Size(1920, 1088),
      ),
    );
    await waitOutSettle(tester);

    expect(pinned, [landscape]);

    await tester.pumpWidget(const SizedBox());
  }, variant: texturePlatform);

  testWidgets('leaving hands a pinned handset back to portrait', (
    tester,
  ) async {
    await pumpPhone(tester);
    await settle(tester);
    await sendEvent(tester, upright(1920, 1080, position: 1500));
    await waitOutSettle(tester);
    pinned.clear();

    await tester.pumpWidget(const SizedBox());

    expect(pinned, [
      ['DeviceOrientation.portraitUp'],
    ]);
  }, variant: texturePlatform);

  testWidgets('a player closed before the first frame leaves rotation alone', (
    tester,
  ) async {
    await pumpPhone(tester);
    await settle(tester);
    pinned.clear();

    // No size ever arrived - an unresolvable stream, or a viewer who changed
    // their mind while the spinner was up. Nothing was pinned, so nothing may
    // be handed back: pinning portraitUp here killed rotation app-wide for the
    // rest of the process.
    await tester.pumpWidget(const SizedBox());

    expect(pinned, isEmpty);
  }, variant: texturePlatform);

  testWidgets('closing during the settle rotates nothing after the fact', (
    tester,
  ) async {
    await pumpPhone(tester);
    await settle(tester);
    pinned.clear();

    // The shape arrived, the clock started, and the viewer left before it ran
    // out. A settle that outlived the screen would turn the device under
    // whatever they went back to.
    await sendEvent(tester, upright(1920, 1080, position: 1500));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(
      PlayerPlatformService.shapeSettleDelay + const Duration(milliseconds: 1),
    );

    expect(pinned, isEmpty);
  }, variant: texturePlatform);

  testWidgets('the action strip offers no rotate button', (tester) async {
    await pumpPhone(tester);
    await settle(tester);
    await sendEvent(tester, upright(1920, 1080, position: 1500));
    await waitOutSettle(tester);

    // Read off the bar's own action list rather than the rendered strip: the
    // strip scrolls on a handset, so a button squeezed off its end is still a
    // button the viewer can reach.
    final PlayerBottomBar bar = tester.widget<PlayerBottomBar>(
      find.byType(PlayerBottomBar),
    );
    expect(
      bar.actions.whereType<PlayerIconButton>().map((b) => b.icon),
      isNot(contains(Icons.screen_rotation)),
      reason:
          'the video decides which way up this is; there is nothing left for '
          'a rotate button to offer',
    );

    await tester.pumpWidget(const SizedBox());
  }, variant: texturePlatform);
}
