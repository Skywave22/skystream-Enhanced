/// Desktop must not let `screen_brightness` talk to the monitor.
///
/// The plugin's Windows side issues DDC/CI — I²C over the display link — to
/// read and write the monitor's own brightness. Its constructor probes once,
/// and it then installs a window-proc delegate that re-probes on `WM_SIZE` and
/// `WM_ACTIVATEAPP` and *writes* on `WM_DESTROY`, `WM_CLOSE` and deactivate,
/// because `is_auto_reset_` defaults to true. Users have reported SkyStream
/// resetting their screen brightness on Windows: that is this write, observed.
///
/// None of it buys anything here. The only caller of the brightness API is the
/// player's touch rail, and it returns early on desktop
/// (`vlc_player_controls.dart`, `if (_isDesktop) return; // no touch rails`),
/// so on a desktop the plugin only ever puts traffic on the display link.
///
/// `setAutoReset(false)` is the cheap half of the fix: it stops every
/// per-activation probe and the pause-time write. It does not stop the
/// constructor's first probe — only keeping the plugin off the desktop build
/// does that. Mobile keeps auto-reset ON, where restoring system brightness
/// when the app leaves the foreground is the behaviour a user wants.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/providers/bootstrap_provider.dart';

/// The channel the `screen_brightness` federated plugin speaks on.
const MethodChannel _brightnessChannel = MethodChannel(
  'github.com/aaassseee/screen_brightness',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Every call the brightness plugin was asked for, in order.
  late List<MethodCall> brightnessCalls;

  setUp(() {
    brightnessCalls = [];
    // Process-wide latch, so it has to be handed back between tests.
    debugResetDesktopBrightnessQuieted();
    messenger.setMockMethodCallHandler(_brightnessChannel, (call) async {
      brightnessCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_brightnessChannel, null);
  });

  /// The calls made with `setAutoReset`, unwrapped to their argument.
  List<bool> autoResetArgs() => brightnessCalls
      .where((c) => c.method == 'setAutoReset')
      .map((c) => (c.arguments as Map<Object?, Object?>)['isAutoReset'] as bool)
      .toList();

  test('a desktop launch switches auto-reset off', () async {
    // The host running these tests is a desktop, which is the case under test.
    await quietDesktopBrightness();

    expect(
      autoResetArgs(),
      [false],
      reason:
          'with auto-reset on, every activation and every close issues DDC/CI '
          'to the monitor for a feature the desktop cannot reach',
    );
  });

  test('it is asked exactly once, not once per call site', () async {
    await quietDesktopBrightness();
    await quietDesktopBrightness();

    expect(
      autoResetArgs().length,
      1,
      reason: 'the second call is a no-op; the flag is already off',
    );
  });

  test('nothing else is asked of the plugin', () async {
    await quietDesktopBrightness();

    expect(
      brightnessCalls.map((c) => c.method).toSet(),
      {'setAutoReset'},
      reason:
          'reading or setting brightness here would be the very traffic this '
          'is removing',
    );
  });
}
