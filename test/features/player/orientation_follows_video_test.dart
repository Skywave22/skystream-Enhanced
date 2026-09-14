import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/features/player/presentation/player_platform_service.dart';
import 'package:skystream/features/player/presentation/widgets/player_control_components.dart'
    show PlayerBottomBar, PlayerIconButton;

import 'vlc_screen_harness.dart';

/// The player's orientation follows the video, and only the video. Each rule
/// is pinned on the real screen over the real engine channel.
///
/// The decision comes off `displayVideoSize`, not `videoSize`: the latter is
/// the elementary stream's declared width and height on every backend, so a
/// clip shot in portrait reports 1920x1080. Android forwards the track's own
/// orientation field and the texture platforms report a coded buffer libVLC
/// has already rotated; a backend that offers neither pins nothing rather than
/// guessing.
///
/// A shape has to hold for [PlayerPlatformService.shapeSettleDelay] rather
/// than arrive twice, because the natives drop a snapshot identical to the one
/// before it and a paused engine sends none at all. `restoreOrientation`
/// unpins only what was pinned, since nothing else in the app calls
/// `setPreferredOrientations`. There is no manual rotate button.
///
/// The pin is a pair — landscapeLeft and landscapeRight, portraitUp and
/// portraitDown — so the viewer can still turn the handset end for end.
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
    int? orientation,
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
    // libVLC's raw `libvlc_video_orient_t`. Android's route to the same answer
    // the texture platforms reach through the coded buffer.
    'videoOrientation': ?orientation,
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

      // What a handset camera writes: landscape frames plus a 90-degree
      // rotation matrix. The media track therefore declares 1920x1080 -
      // `libvlc_video_get_size` reads `libvlc_media_get_tracks_info`, a struct
      // with no orientation member - while the buffer libVLC decodes into is
      // 1088x1920, because `vmem.c` runs `video_format_ApplyRotation` before
      // it hands the format to the sink.
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

    // Android's shipping path is an AndroidView platform view, which sends
    // `videoSize` and no `codedSize`. That one size cannot tell a landscape
    // film from a portrait clip shot on a phone, so the player leaves the
    // device wherever the viewer's own rotation setting has it.
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
          'a rotation-blind size is not evidence, and a coin flip behind a '
          'device rotation is worse than leaving the handset alone',
    );

    await tester.pumpWidget(const SizedBox());
  }, variant: texturePlatform);

  testWidgets('Android turns the handset from the track\'s own rotation', (
    tester,
  ) async {
    await pumpPhone(tester);
    await settle(tester);
    pinned.clear();

    // Android sends no coded buffer, so its route to the upright shape is the
    // rotation field beside the size. Shot in portrait on a handset, and
    // therefore stored as landscape frames plus a quarter turn: orientation 6,
    // RightTop, is what an MP4 tkhd matrix of 270 degrees becomes.
    await sendEvent(
      tester,
      event(position: 1500, track: const Size(1920, 1080), orientation: 6),
    );
    await waitOutSettle(tester);

    expect(
      pinned,
      [portrait],
      reason:
          'the stored frames are landscape; the picture is not. Android has '
          'the rotation in the same track read as the size, so there is '
          'nothing to guess at here',
    );

    await tester.pumpWidget(const SizedBox());
  }, variant: texturePlatform);

  testWidgets('Android leaves a genuinely landscape film in landscape', (
    tester,
  ) async {
    await pumpPhone(tester);
    await settle(tester);
    pinned.clear();

    // The same stored dimensions with no rotation on them at all.
    await sendEvent(
      tester,
      event(position: 1500, track: const Size(1920, 1080), orientation: 0),
    );
    await waitOutSettle(tester);

    expect(pinned, [landscape]);

    await tester.pumpWidget(const SizedBox());
  }, variant: texturePlatform);

  testWidgets('a shape revised during startup turns the handset once', (
    tester,
  ) async {
    await pumpPhone(tester);
    await settle(tester);
    pinned.clear();

    // A first reading, replaced a tick later by the one that sticks. Only the
    // shape that stuck may reach the OS: the viewer must not watch the device
    // swing landscape and back.
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

    // One snapshot, and then silence. Every native side drops a snapshot
    // identical to the one before it, so a paused engine has nothing further
    // to say, and the controller's stall clock - which does re-publish while
    // playback is running - is inert while the state is paused.
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
    // be handed back: pinning portraitUp here would kill rotation app-wide for
    // the rest of the process.
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
