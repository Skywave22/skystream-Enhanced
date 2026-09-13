import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/features/player/presentation/player_platform_service.dart';

const _pipChannel = 'dev.akash.skystream.player/pip';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Every orientation list handed to SystemChrome, in order. Empty means the
  /// call under test left the device alone, which several of these assert.
  late List<List<String>> pinned;

  setUp(() {
    pinned = [];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        pinned.add(List<String>.from(call.arguments as List<Object?>));
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    PlayerPlatformService().detachPipListener();
  });

  /// Delivers a call the way MainActivity does: fire-and-forget, no result.
  Future<void> fromNative(String method, [Object? arguments]) {
    return messenger.handlePlatformMessage(
      _pipChannel,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, arguments),
      ),
      null,
    );
  }

  group('playerFormFactorOf', () {
    test('an unresolved profile is unknown, not a guess', () {
      expect(playerFormFactorOf(null), PlayerFormFactor.unknown);
    });

    test('television wins over the tablet-sized screen it also reports', () {
      expect(
        playerFormFactorOf(const DeviceProfile(isTv: true, isTablet: true)),
        PlayerFormFactor.tv,
      );
    });

    test('desktop, tablet and phone map through', () {
      expect(
        playerFormFactorOf(const DeviceProfile(isDesktopOS: true)),
        PlayerFormFactor.desktop,
      );
      expect(
        playerFormFactorOf(const DeviceProfile(isTablet: true)),
        PlayerFormFactor.tablet,
      );
      expect(playerFormFactorOf(const DeviceProfile()), PlayerFormFactor.phone);
    });

    test('full screen mode is a television, whatever the hardware says', () {
      // The whole point of the flag: a desktop plugged into a TV gets the
      // ten-foot player without a single widget learning a new parameter.
      addTearDown(() => fullScreenModeActive.value = false);
      const desktop = DeviceProfile(isDesktopOS: true);

      expect(playerFormFactorOf(desktop), PlayerFormFactor.desktop);

      fullScreenModeActive.value = true;
      expect(playerFormFactorOf(desktop), PlayerFormFactor.tv);
      expect(
        playerFormFactorOf(null),
        PlayerFormFactor.unknown,
        reason:
            'full screen mode changes the verdict, it does not manufacture '
            'one before the device profile has resolved',
      );

      fullScreenModeActive.value = false;
      expect(playerFormFactorOf(desktop), PlayerFormFactor.desktop);
    });

    test('only phone and tablet may be pinned', () {
      expect(
        PlayerFormFactor.values.where((f) => f.pinsOrientation),
        unorderedEquals([PlayerFormFactor.phone, PlayerFormFactor.tablet]),
      );
    });

    test('only phone and tablet are driven by a finger', () {
      // The gate for the screen lock. It names the same two members as
      // `pinsOrientation` today and means something else entirely - "is a
      // finger the only thing that drives this" against "may this be pinned
      // to an orientation" - so the two are pinned separately on purpose. An
      // orientation decision must never be able to take the lock away.
      expect(
        PlayerFormFactor.values.where((f) => f.isTouch),
        unorderedEquals([PlayerFormFactor.phone, PlayerFormFactor.tablet]),
      );
      expect(PlayerFormFactor.tv.isTouch, isFalse);
      expect(PlayerFormFactor.desktop.isTouch, isFalse);
      expect(
        PlayerFormFactor.unknown.isTouch,
        isFalse,
        reason: 'an unresolved profile is still "do not touch"',
      );
    });
  });

  group('PiP listener', () {
    test('routes every transport button MainActivity can send', () async {
      final actions = <PipAction>[];
      PlayerPlatformService().attachPipListener(
        onAction: actions.add,
        onModeChanged: (_) {},
      );

      await fromNative('play');
      await fromNative('pause');
      await fromNative('seekForward');
      await fromNative('seekBackward');

      expect(actions, [
        PipAction.play,
        PipAction.pause,
        PipAction.seekForward,
        PipAction.seekBackward,
      ]);
    });

    test('surfaces pipModeChanged both ways', () async {
      final modes = <bool>[];
      PlayerPlatformService().attachPipListener(
        onAction: (_) {},
        onModeChanged: modes.add,
      );

      await fromNative('pipModeChanged', true);
      await fromNative('pipModeChanged', false);

      expect(modes, [true, false]);
    });

    test(
      'a malformed mode argument reads as "not in PiP", never a throw',
      () async {
        final modes = <bool>[];
        PlayerPlatformService().attachPipListener(
          onAction: (_) {},
          onModeChanged: modes.add,
        );

        await fromNative('pipModeChanged', null);
        await fromNative('pipModeChanged', 'yes');

        expect(modes, [false, false]);
      },
    );

    test('an unknown method is ignored rather than raised', () async {
      var fired = false;
      PlayerPlatformService().attachPipListener(
        onAction: (_) => fired = true,
        onModeChanged: (_) => fired = true,
      );

      await expectLater(fromNative('somethingElse'), completes);
      expect(fired, isFalse);
    });

    test('detach stops delivery to a screen that is gone', () async {
      final actions = <PipAction>[];
      final service = PlayerPlatformService()
        ..attachPipListener(onAction: actions.add, onModeChanged: (_) {});

      service.detachPipListener();
      await fromNative('play');

      expect(actions, isEmpty);
    });
  });

  /// The window has to be shaped like the film. MainActivity cannot work the
  /// shape out for itself - the decoded size lives in the Dart controller -
  /// so if these arguments are not on the wire the aspect ratio is whatever
  /// Android happened to use last, and a 2.39:1 film is letterboxed inside a
  /// window that is already small.
  group('PiP video size', () {
    late List<MethodCall> sent;

    setUp(() {
      sent = [];
      // Overridden rather than read: `Platform.isAndroid` is false on the host
      // running these tests, so without this the call under test returns
      // before it sends anything and the assertions below would pass against
      // any implementation at all.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      messenger.setMockMethodCallHandler(const MethodChannel(_pipChannel), (
        call,
      ) async {
        sent.add(call);
        return call.method == 'enterPip' ? true : null;
      });
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(
        const MethodChannel(_pipChannel),
        null,
      );
    });

    test(
      'enterPip carries the decoded size alongside the play state',
      () async {
        final entered = await PlayerPlatformService().enterPip(
          true,
          videoSize: const Size(1920, 800),
        );

        expect(entered, isTrue);
        expect(sent.single.method, 'enterPip');
        expect(sent.single.arguments, {
          'isPlaying': true,
          'videoWidth': 1920,
          'videoHeight': 800,
        });
      },
    );

    test(
      'a size that has not been decoded yet is left off the message',
      () async {
        await PlayerPlatformService().enterPip(false);
        await PlayerPlatformService().enterPip(false, videoSize: Size.zero);

        // Not zero, and not a guess at square: MainActivity keeps the last
        // shape it was given, and Android throws IllegalArgumentException out
        // of enterPictureInPictureMode for a ratio it will not accept.
        expect(sent.map((c) => c.arguments), [
          {'isPlaying': false},
          {'isPlaying': false},
        ]);
      },
    );

    test('a mid-window episode change re-shapes through setPipState', () async {
      PlayerPlatformService().syncPipState(
        true,
        videoSize: const Size(1280, 720),
      );
      await Future<void>.delayed(Duration.zero);

      expect(sent.single.method, 'setPipState');
      expect(sent.single.arguments, {
        'isPlaying': true,
        'videoWidth': 1280,
        'videoHeight': 720,
      });
    });
  });

  /// One reading of the rendered picture's shape, as the screen feeds it:
  /// every playback tick, not only the ticks where the size changed.
  ///
  /// A `Size` and not a width/height pair, and the *rendered* size and not the
  /// track's declared one — see [PlayerPlatformService.applyVideoOrientation]
  /// for why the track's size cannot be used to decide this.
  void read(
    PlayerPlatformService service,
    PlayerFormFactor form,
    Size? renderedSize, {
    int times = 1,
  }) {
    for (var i = 0; i < times; i++) {
      service.applyVideoOrientation(form, renderedSize: renderedSize);
    }
  }

  /// Waits the shape out, plus the tick that fires the timer.
  Future<void> waitOutSettle(WidgetTester tester) =>
      tester.pump(PlayerPlatformService.shapeSettleDelay + _oneTick);

  const landscape = [
    'DeviceOrientation.landscapeLeft',
    'DeviceOrientation.landscapeRight',
  ];
  const portrait = [
    'DeviceOrientation.portraitUp',
    'DeviceOrientation.portraitDown',
  ];

  // A rendered buffer, which is what the decoder writes into: the padded,
  // upright picture. 1080p pads to 1088 rows; a portrait clip is the same
  // buffer transposed, because libVLC applies the file's rotation before it
  // ever reaches a sink.
  const landscapeBuffer = Size(1920, 1088);
  const portraitBuffer = Size(1088, 1920);

  group('applyVideoOrientation', () {
    testWidgets('a shape is believed once it has held, and not before', (
      tester,
    ) async {
      final service = PlayerPlatformService();

      read(service, PlayerFormFactor.phone, landscapeBuffer);
      await tester.pump(PlayerPlatformService.shapeSettleDelay - _oneTick);
      expect(
        pinned,
        isEmpty,
        reason:
            'libVLC revises the track it reports during startup, so a shape '
            'that has only just arrived is a candidate, not a verdict',
      );

      await waitOutSettle(tester);
      expect(
        pinned,
        [landscape],
        reason:
            'ONE reading is enough once it has held. The rule this replaced '
            'wanted two consecutive matching EVENTS, which a player paused on '
            'its first frame never gets: the natives drop a snapshot '
            'identical to the last one, and a paused engine sends none at all',
      );

      service.restoreOrientation(PlayerFormFactor.phone);
    });

    testWidgets('a film ticking the same shape does not push the settle back', (
      tester,
    ) async {
      final service = PlayerPlatformService();

      // Four ticks a second, all agreeing, for almost the whole window. A
      // settle that restarted its clock on every reading would never fire.
      for (
        var elapsed = Duration.zero;
        elapsed < PlayerPlatformService.shapeSettleDelay;
        elapsed += const Duration(milliseconds: 250)
      ) {
        read(service, PlayerFormFactor.phone, landscapeBuffer);
        await tester.pump(const Duration(milliseconds: 250));
      }

      expect(pinned, [landscape]);

      service.restoreOrientation(PlayerFormFactor.phone);
    });

    testWidgets(
      'a shape revised during startup rotates the device once, not twice',
      (tester) async {
        final service = PlayerPlatformService();

        // The reading that used to be acted on immediately, and the one that
        // replaced it a beat later. Only the shape that stuck may reach the OS.
        read(service, PlayerFormFactor.phone, landscapeBuffer);
        await tester.pump(const Duration(milliseconds: 250));
        read(service, PlayerFormFactor.phone, portraitBuffer, times: 3);
        await waitOutSettle(tester);

        expect(pinned, [portrait]);

        service.restoreOrientation(PlayerFormFactor.phone);
      },
    );

    testWidgets('a settled shape is never re-sent, at any resolution', (
      tester,
    ) async {
      final service = PlayerPlatformService();
      read(service, PlayerFormFactor.phone, const Size(1280, 720));
      await waitOutSettle(tester);
      expect(pinned, [landscape]);

      // The rest of the film, with an HLS variant switch part way through.
      // Same verdict, so not one further platform message.
      read(service, PlayerFormFactor.phone, const Size(1280, 720), times: 10);
      read(service, PlayerFormFactor.phone, landscapeBuffer, times: 10);
      await waitOutSettle(tester);

      expect(pinned, [landscape]);

      service.restoreOrientation(PlayerFormFactor.phone);
    });

    testWidgets('a portrait clip pins portrait, on a phone and on a tablet', (
      tester,
    ) async {
      final phone = PlayerPlatformService();
      final tablet = PlayerPlatformService();
      read(phone, PlayerFormFactor.phone, portraitBuffer);
      read(tablet, PlayerFormFactor.tablet, portraitBuffer);
      await waitOutSettle(tester);

      expect(pinned, [portrait, portrait]);

      phone.restoreOrientation(PlayerFormFactor.phone);
      tablet.restoreOrientation(PlayerFormFactor.tablet);
    });

    testWidgets('a square video counts as landscape', (tester) async {
      final service = PlayerPlatformService();
      read(service, PlayerFormFactor.phone, const Size(720, 720));
      await waitOutSettle(tester);

      expect(pinned.single, landscape);

      service.restoreOrientation(PlayerFormFactor.phone);
    });

    testWidgets('sizes that are not known yet are left alone', (tester) async {
      final service = PlayerPlatformService();
      read(service, PlayerFormFactor.phone, null, times: 2);
      read(service, PlayerFormFactor.phone, Size.zero, times: 2);
      read(service, PlayerFormFactor.phone, const Size(1920, 0), times: 2);
      await waitOutSettle(tester);

      expect(pinned, isEmpty);
    });

    testWidgets('an unknown size mid-settle stops the clock', (tester) async {
      final service = PlayerPlatformService();

      read(service, PlayerFormFactor.phone, portraitBuffer);
      await tester.pump(const Duration(milliseconds: 250));
      // setMedia clears the size, which is "not known" and not agreement.
      read(service, PlayerFormFactor.phone, null);
      await waitOutSettle(tester);
      expect(pinned, isEmpty);

      read(service, PlayerFormFactor.phone, portraitBuffer);
      await waitOutSettle(tester);
      expect(pinned, [portrait]);

      service.restoreOrientation(PlayerFormFactor.phone);
    });

    testWidgets(
      'the next episode re-settles, and holds the old pin until it does',
      (tester) async {
        final service = PlayerPlatformService();
        read(service, PlayerFormFactor.phone, landscapeBuffer);
        await waitOutSettle(tester);
        pinned.clear();

        // The gap between two episodes: state goes to `opening`, which clears
        // the size. The device must not swing back to portrait in the gap.
        read(service, PlayerFormFactor.phone, null, times: 4);
        await waitOutSettle(tester);
        expect(pinned, isEmpty);

        read(service, PlayerFormFactor.phone, portraitBuffer);
        await waitOutSettle(tester);
        expect(pinned, [portrait]);

        service.restoreOrientation(PlayerFormFactor.phone);
      },
    );

    testWidgets('television and desktop are never pinned', (tester) async {
      for (final form in [
        PlayerFormFactor.tv,
        PlayerFormFactor.desktop,
        PlayerFormFactor.unknown,
      ]) {
        read(PlayerPlatformService(), form, landscapeBuffer, times: 4);
      }
      await waitOutSettle(tester);

      expect(pinned, isEmpty);
    });

    testWidgets('a form factor that stops pinning mid-settle disarms it', (
      tester,
    ) async {
      final service = PlayerPlatformService();

      // Full screen mode turns a phone into a television between two ticks.
      // The candidate armed a moment ago must not go on to rotate it.
      read(service, PlayerFormFactor.phone, landscapeBuffer);
      await tester.pump(const Duration(milliseconds: 250));
      read(service, PlayerFormFactor.tv, landscapeBuffer);
      await waitOutSettle(tester);

      expect(pinned, isEmpty);
    });

    testWidgets('a profile that resolves late still gets the full settle', (
      tester,
    ) async {
      final service = PlayerPlatformService();

      // Readings while the device profile is still in flight arm nothing, so
      // the first reading after it lands is the one that starts the clock.
      read(service, PlayerFormFactor.unknown, portraitBuffer, times: 6);
      await waitOutSettle(tester);
      expect(pinned, isEmpty);

      read(service, PlayerFormFactor.phone, portraitBuffer);
      await waitOutSettle(tester);
      expect(pinned, [portrait]);

      service.restoreOrientation(PlayerFormFactor.phone);
    });
  });

  group('restoreOrientation', () {
    testWidgets(
      'a phone that was pinned goes back to portrait, not to a free-for-all',
      (tester) async {
        final service = PlayerPlatformService();
        read(service, PlayerFormFactor.phone, landscapeBuffer);
        await waitOutSettle(tester);
        pinned.clear();

        service.restoreOrientation(PlayerFormFactor.phone);

        expect(pinned.single, ['DeviceOrientation.portraitUp']);
      },
    );

    testWidgets(
      'a tablet that was pinned is released to whatever the platform allows',
      (tester) async {
        final service = PlayerPlatformService();
        read(service, PlayerFormFactor.tablet, landscapeBuffer);
        await waitOutSettle(tester);
        pinned.clear();

        service.restoreOrientation(PlayerFormFactor.tablet);

        expect(pinned.single, isEmpty);
      },
    );

    testWidgets('a player closed before the first frame leaves the device '
        'alone', (tester) async {
      final service = PlayerPlatformService();
      // A stream that never resolved, or a viewer who changed their mind: the
      // size never arrived, so nothing was pinned and nothing may be
      // "restored". Pinning portraitUp here froze rotation app-wide for the
      // rest of the process, because nothing else ever calls
      // setPreferredOrientations.
      read(service, PlayerFormFactor.phone, null, times: 4);
      await waitOutSettle(tester);

      service.restoreOrientation(PlayerFormFactor.phone);

      expect(pinned, isEmpty);
    });

    testWidgets('leaving during the settle stops the clock, and pins nothing', (
      tester,
    ) async {
      final service = PlayerPlatformService();
      read(service, PlayerFormFactor.phone, landscapeBuffer);
      await tester.pump(const Duration(milliseconds: 250));

      service.restoreOrientation(PlayerFormFactor.phone);
      await waitOutSettle(tester);

      expect(
        pinned,
        isEmpty,
        reason:
            'a settle that outlived the screen would rotate the device under '
            'whatever the viewer went back to',
      );
    });

    testWidgets('nothing was pinned on TV or desktop, so nothing is restored', (
      tester,
    ) async {
      for (final form in [
        PlayerFormFactor.tv,
        PlayerFormFactor.desktop,
        PlayerFormFactor.unknown,
      ]) {
        PlayerPlatformService().restoreOrientation(form);
      }

      expect(pinned, isEmpty);
    });

    testWidgets('restoring twice hands the device back once', (tester) async {
      final service = PlayerPlatformService();
      read(service, PlayerFormFactor.phone, landscapeBuffer);
      await waitOutSettle(tester);
      pinned.clear();

      service
        ..restoreOrientation(PlayerFormFactor.phone)
        ..restoreOrientation(PlayerFormFactor.phone);

      expect(pinned, hasLength(1));
    });

    testWidgets('the settle starts clean for the next session', (tester) async {
      final service = PlayerPlatformService();
      read(service, PlayerFormFactor.phone, landscapeBuffer);
      await waitOutSettle(tester);
      service.restoreOrientation(PlayerFormFactor.phone);
      pinned.clear();

      read(service, PlayerFormFactor.phone, landscapeBuffer);
      await tester.pump(PlayerPlatformService.shapeSettleDelay - _oneTick);
      expect(
        pinned,
        isEmpty,
        reason: 'the candidate was dropped on the way out',
      );

      await waitOutSettle(tester);
      expect(pinned.single, landscape);

      service.restoreOrientation(PlayerFormFactor.phone);
    });
  });
}

/// One frame at the fake clock's default rate, enough to run a timer that has
/// come due.
const Duration _oneTick = Duration(milliseconds: 1);
