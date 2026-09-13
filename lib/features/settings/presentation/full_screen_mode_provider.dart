/// Full screen mode: the ten-foot mode for a desktop that is plugged into a
/// television. Off, the app is in its ordinary windowed mode.
///
/// Two things happen when it is on, and they are deliberately not the same
/// thing:
///  * the window goes full screen, and
///  * the player answers [PlayerFormFactor.tv] instead of `desktop`, which is
///    what actually buys the ten-foot layout — see [fullScreenModeActive] and
///    `playerFormFactorOf`.
///
/// The second is the point. Threading an `isFullScreenMode` bool through every
/// widget that already branches on "is this a TV" would be sixteen more
/// parameters saying what the form factor already says.
///
/// Not to be confused with the player's own full-screen button
/// (`vlc_player_controls.dart`, tooltip `l10n.fullscreen`/`l10n.windowed`),
/// which moves the window and nothing else. This mode moves the window *and*
/// the layout, which is why it is a setting rather than a transport control.
library;

import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../player/presentation/player_platform_service.dart';

part 'full_screen_mode_provider.g.dart';

/// The launch arguments that boot straight into full screen mode, for a
/// desktop shortcut or a "start on the television" entry.
///
/// Every spelling is accepted because every spelling gets typed. The two
/// `--big-picture` forms are the feature's retired name, kept as aliases so
/// that a shortcut or launcher script written against the old spelling keeps
/// working; new ones should use `--full-screen`.
const Set<String> kFullScreenModeLaunchArgs = <String>{
  '--full-screen',
  '--fullscreen',
  '--big-picture',
  '--bigpicture',
};

/// Whether the app is in full screen mode right now, and the toggle for it.
///
/// The state is *not* stored here. [fullScreenModeActive] is the single
/// owner — it has to be, because `playerFormFactorOf` is a plain function
/// with no `ref` — and this notifier is the widget tree's view of it.
/// Anything that flips the flag, from here or from a launch argument,
/// arrives through the listener below, so the two can never disagree the way
/// a mirrored copy would.
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
  /// desktop binary only ever hands its arguments to `main`, and because a
  /// function of its input is a function a test can call.
  void initialize(List<String> launchArgs) {
    if (launchArgs.any(kFullScreenModeLaunchArgs.contains)) {
      unawaited(setEnabled(true));
    }
  }

  /// Switches between full screen and windowed, window and layout together.
  ///
  /// The flag is set before the window is asked to move: the layout switch is
  /// ours and instant, the window transition belongs to the OS, is animated on
  /// macOS, and may be refused outright. Waiting on it would leave the UI
  /// looking hung for the length of an animation it does not depend on.
  Future<void> setEnabled(bool enabled) async {
    if (enabled == fullScreenModeActive.value) return;
    fullScreenModeActive.value = enabled;
    await PlayerPlatformService().setFullscreen(enabled);
  }
}
