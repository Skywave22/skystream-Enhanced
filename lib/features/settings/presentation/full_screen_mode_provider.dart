/// Full screen mode: the ten-foot mode for a desktop plugged into a television.
///
/// Turning it on full-screens the window and makes the player answer
/// [PlayerFormFactor.tv] instead of `desktop`, which is what buys the ten-foot
/// layout. The player's own full-screen button in `vlc_player_controls.dart`
/// moves the window and nothing else.
library;

import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../player/presentation/player_platform_service.dart';

part 'full_screen_mode_provider.g.dart';

/// The launch arguments that boot straight into full screen mode.
///
/// The `--big-picture` forms are the feature's retired name, kept so that a
/// shortcut written against the old spelling keeps working.
const Set<String> kFullScreenModeLaunchArgs = <String>{
  '--full-screen',
  '--fullscreen',
  '--big-picture',
  '--bigpicture',
};

/// Whether the app is in full screen mode right now, and the toggle for it.
///
/// The state lives in [fullScreenModeActive], not here, because
/// `playerFormFactorOf` is a plain function with no `ref`. This notifier
/// mirrors it through a listener, so the two can never disagree.
@Riverpod(keepAlive: true)
class FullScreenMode extends _$FullScreenMode {
  @override
  bool build() {
    void sync() => state = fullScreenModeActive.value;
    fullScreenModeActive.addListener(sync);
    ref.onDispose(() => fullScreenModeActive.removeListener(sync));
    return fullScreenModeActive.value;
  }

  /// Honours [kFullScreenModeLaunchArgs] on the command line.
  ///
  /// Takes the argument list rather than reading it, because a compiled
  /// desktop binary only ever hands its arguments to `main`.
  void initialize(List<String> launchArgs) {
    if (launchArgs.any(kFullScreenModeLaunchArgs.contains)) {
      unawaited(setEnabled(true));
    }
  }

  /// Switches between full screen and windowed, window and layout together.
  ///
  /// The flag is set before the window is asked to move: the OS transition is
  /// animated on macOS and may be refused outright, and the layout must not
  /// wait on it.
  Future<void> setEnabled(bool enabled) async {
    if (enabled == fullScreenModeActive.value) return;
    fullScreenModeActive.value = enabled;
    await PlayerPlatformService().setFullscreen(enabled);
  }
}
