/// Big Picture: the ten-foot mode for a desktop that is plugged into a
/// television.
///
/// Two things happen when it is on, and they are deliberately not the same
/// thing:
///  * the window goes full screen, and
///  * the player answers [PlayerFormFactor.tv] instead of `desktop`, which is
///    what actually buys the ten-foot layout — see [bigPictureActive] and
///    `playerFormFactorOf`.
///
/// The second is the point. Threading a `isBigPicture` bool through every
/// widget that already branches on "is this a TV" would be sixteen more
/// parameters saying what the form factor already says.
library;

import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../player/presentation/player_platform_service.dart';

part 'big_picture_provider.g.dart';

/// The launch arguments that boot straight into Big Picture, for a desktop
/// shortcut or a Steam-style "start on the TV" entry.
///
/// Both spellings are accepted because both get typed.
const Set<String> kBigPictureLaunchArgs = <String>{
  '--big-picture',
  '--bigpicture',
};

/// Whether the app is in Big Picture right now, and the toggle for it.
///
/// The state is *not* stored here. [bigPictureActive] is the single owner —
/// it has to be, because `playerFormFactorOf` is a plain function with no
/// `ref` — and this notifier is the widget tree's view of it. Anything that
/// flips the flag, from here or from a launch argument, arrives through the
/// listener below, so the two can never disagree the way a mirrored copy
/// would.
@Riverpod(keepAlive: true)
class BigPictureMode extends _$BigPictureMode {
  @override
  bool build() {
    void sync() => state = bigPictureActive.value;
    bigPictureActive.addListener(sync);
    ref.onDispose(() => bigPictureActive.removeListener(sync));
    return bigPictureActive.value;
  }

  /// Honours `--big-picture` on the command line.
  ///
  /// Takes the argument list rather than reading it, because a compiled
  /// desktop binary only ever hands its arguments to `main`, and because a
  /// function of its input is a function a test can call.
  void initialize(List<String> launchArgs) {
    if (launchArgs.any(kBigPictureLaunchArgs.contains)) {
      unawaited(setEnabled(true));
    }
  }

  /// Turns Big Picture on or off, window and layout together.
  ///
  /// The flag is set before the window is asked to move: the layout switch is
  /// ours and instant, the window transition belongs to the OS, is animated on
  /// macOS, and may be refused outright. Waiting on it would leave the UI
  /// looking hung for the length of an animation it does not depend on.
  Future<void> setEnabled(bool enabled) async {
    if (enabled == bigPictureActive.value) return;
    bigPictureActive.value = enabled;
    await PlayerPlatformService().setFullscreen(enabled);
  }
}
