/// Full screen mode: the ten-foot mode for a desktop plugged into a television.
///
/// Turning it on full-screens the window and makes the player answer
/// [PlayerFormFactor.tv] instead of `desktop`, which is what buys the ten-foot
/// layout. The player's own full-screen button in `vlc_player_controls.dart`
/// moves the window and nothing else.
library;

import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/storage/settings_repository.dart';
import '../../player/presentation/player_platform_service.dart';

part 'full_screen_mode_provider.g.dart';

/// Whether the app is in full screen mode right now, and the toggle for it.
///
/// The state lives in [fullScreenModeActive], not here, because
/// `playerFormFactorOf` is a plain function with no `ref`. This notifier
/// mirrors it through a listener, so the two can never disagree.
@Riverpod(keepAlive: true)
class FullScreenMode extends _$FullScreenMode {
  late SettingsRepository _repository;

  @override
  bool build() {
    _repository = ref.watch(settingsRepositoryProvider);
    void sync() => state = fullScreenModeActive.value;
    fullScreenModeActive.addListener(sync);
    ref.onDispose(() => fullScreenModeActive.removeListener(sync));
    return fullScreenModeActive.value;
  }

  /// Restores the last session's choice.
  ///
  /// There used to be a `--full-screen` launch flag here as well. Only the
  /// three desktop platforms can pass an argument at all, so it made the same
  /// build behave differently depending on how it was started and gave the
  /// desktop a way in that the phone and the television had no equivalent
  /// for. The setting it used to force is remembered now, which is what the
  /// flag was really being used for.
  void initialize() {
    if (_repository.getFullScreenMode() ?? false) {
      unawaited(_apply(true));
    }
  }

  /// Switches between full screen and windowed, and remembers the choice.
  ///
  /// This is the Settings switch. [initialize] deliberately goes around it:
  /// restoring a saved state is not a new choice, and writing it back on every
  /// launch would keep rewriting the same value.
  Future<void> setEnabled(bool enabled) async {
    await _apply(enabled);
    await _repository.setFullScreenMode(enabled);
  }

  /// Moves the window and the layout, recording nothing.
  ///
  /// The flag is set before the window is asked to move: the OS transition is
  /// animated on macOS and may be refused outright, and the layout must not
  /// wait on it.
  Future<void> _apply(bool enabled) async {
    if (enabled == fullScreenModeActive.value) return;
    fullScreenModeActive.value = enabled;
    await PlayerPlatformService().setFullscreen(enabled);
  }
}
