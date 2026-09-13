import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
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

  group('applyVideoOrientation', () {
    test(
      'a landscape video pins landscape, a portrait video pins portrait',
      () {
        PlayerPlatformService().applyVideoOrientation(
          PlayerFormFactor.phone,
          width: 1920,
          height: 1080,
        );
        PlayerPlatformService().applyVideoOrientation(
          PlayerFormFactor.tablet,
          width: 1080,
          height: 1920,
        );

        expect(pinned, [
          [
            'DeviceOrientation.landscapeLeft',
            'DeviceOrientation.landscapeRight',
          ],
          ['DeviceOrientation.portraitUp', 'DeviceOrientation.portraitDown'],
        ]);
      },
    );

    test('a square video counts as landscape', () {
      PlayerPlatformService().applyVideoOrientation(
        PlayerFormFactor.phone,
        width: 720,
        height: 720,
      );

      expect(pinned.single, [
        'DeviceOrientation.landscapeLeft',
        'DeviceOrientation.landscapeRight',
      ]);
    });

    test('sizes that are not known yet are left alone', () {
      final service = PlayerPlatformService();
      service.applyVideoOrientation(
        PlayerFormFactor.phone,
        width: null,
        height: 1080,
      );
      service.applyVideoOrientation(
        PlayerFormFactor.phone,
        width: 1920,
        height: null,
      );
      service.applyVideoOrientation(
        PlayerFormFactor.phone,
        width: 0,
        height: 0,
      );

      expect(pinned, isEmpty);
    });

    test('television and desktop are never pinned', () {
      for (final form in [
        PlayerFormFactor.tv,
        PlayerFormFactor.desktop,
        PlayerFormFactor.unknown,
      ]) {
        PlayerPlatformService().applyVideoOrientation(
          form,
          width: 1920,
          height: 1080,
        );
      }

      expect(pinned, isEmpty);
    });
  });

  group('toggleOrientation', () {
    test('flips to the other pair', () {
      PlayerPlatformService().toggleOrientation(
        PlayerFormFactor.phone,
        Orientation.landscape,
      );
      PlayerPlatformService().toggleOrientation(
        PlayerFormFactor.phone,
        Orientation.portrait,
      );

      expect(pinned, [
        ['DeviceOrientation.portraitUp', 'DeviceOrientation.portraitDown'],
        ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight'],
      ]);
    });

    test('does nothing on a television', () {
      PlayerPlatformService().toggleOrientation(
        PlayerFormFactor.tv,
        Orientation.landscape,
      );

      expect(pinned, isEmpty);
    });

    test('the viewer outranks the next video-size event', () {
      final service = PlayerPlatformService()
        ..toggleOrientation(PlayerFormFactor.phone, Orientation.landscape);
      pinned.clear();

      service.applyVideoOrientation(
        PlayerFormFactor.phone,
        width: 1920,
        height: 1080,
      );

      expect(pinned, isEmpty);
    });

    test('a television toggle does not latch the override', () {
      final service = PlayerPlatformService()
        ..toggleOrientation(PlayerFormFactor.tv, Orientation.landscape);

      service.applyVideoOrientation(
        PlayerFormFactor.phone,
        width: 1920,
        height: 1080,
      );

      expect(pinned, hasLength(1));
    });
  });

  group('restoreOrientation', () {
    test('a phone goes back to portrait, not to a free-for-all', () {
      PlayerPlatformService().restoreOrientation(PlayerFormFactor.phone);

      expect(pinned.single, ['DeviceOrientation.portraitUp']);
    });

    test('a tablet is released to whatever the platform allows', () {
      PlayerPlatformService().restoreOrientation(PlayerFormFactor.tablet);

      expect(pinned.single, isEmpty);
    });

    test('nothing was pinned on TV or desktop, so nothing is restored', () {
      for (final form in [
        PlayerFormFactor.tv,
        PlayerFormFactor.desktop,
        PlayerFormFactor.unknown,
      ]) {
        PlayerPlatformService().restoreOrientation(form);
      }

      expect(pinned, isEmpty);
    });

    test(
      'clears the viewer override so the next session auto-rotates again',
      () {
        final service = PlayerPlatformService()
          ..toggleOrientation(PlayerFormFactor.phone, Orientation.landscape)
          ..restoreOrientation(PlayerFormFactor.phone);
        pinned.clear();

        service.applyVideoOrientation(
          PlayerFormFactor.phone,
          width: 1920,
          height: 1080,
        );

        expect(pinned.single, [
          'DeviceOrientation.landscapeLeft',
          'DeviceOrientation.landscapeRight',
        ]);
      },
    );
  });
}
