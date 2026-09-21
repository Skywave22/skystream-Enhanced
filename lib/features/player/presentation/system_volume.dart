/// The operating system's media volume, behind one seam.
///
/// A seam rather than a direct call so the player's volume logic can be tested
/// without a platform channel, and so the one place that decides whether to
/// touch the system at all is [VolumeRouting] rather than a scattering of
/// platform checks.
///
/// Every method swallows its own failures. The system stream is a courtesy:
/// on a desktop nothing here is ever called, and on a handset a refusal - no
/// permission, a headset transition, a plugin that does not implement the
/// platform - must leave the player's own gain working rather than take the
/// volume control down with it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';

/// Reads and writes the platform's media volume, 0..1.
abstract interface class SystemVolume {
  /// The current level, or null where the platform did not answer.
  Future<double?> read();

  /// Sets the level. Silently does nothing where the platform refuses.
  Future<void> write(double level);

  /// Fires whenever the level changes from outside this app - which on a
  /// handset is the hardware rocker, and is the whole reason the player cannot
  /// simply remember what it last set.
  Stream<double> get changes;

  /// Releases the platform listener.
  void dispose();
}

/// The real one.
class PlatformSystemVolume implements SystemVolume {
  PlatformSystemVolume();

  final StreamController<double> _changes = StreamController<double>.broadcast();
  StreamSubscription<double>? _subscription;

  @override
  Stream<double> get changes {
    // Attached lazily: the plugin registers a platform listener, and a player
    // on a form factor that never reads the system volume should not be
    // holding one.
    _subscription ??= FlutterVolumeController.addListener(
      _changes.add,
      // The player draws its own rail for this. The platform's HUD on top of
      // it would be two readouts of one number, and on Android it covers the
      // top of the video.
      emitOnStart: false,
    );
    return _changes.stream;
  }

  @override
  Future<double?> read() async {
    try {
      return await FlutterVolumeController.getVolume();
    } catch (error) {
      if (kDebugMode) debugPrint('system volume read failed: $error');
      return null;
    }
  }

  @override
  Future<void> write(double level) async {
    try {
      await FlutterVolumeController.setVolume(level.clamp(0.0, 1.0));
    } catch (error) {
      if (kDebugMode) debugPrint('system volume write failed: $error');
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    FlutterVolumeController.removeListener();
    unawaited(_changes.close());
  }
}

/// Hides the platform's own volume HUD for as long as the player is up.
///
/// The player draws a rail of its own off the same number, and two of them at
/// once is one too many - on Android the system's sits over the top of the
/// video. Restored on the way out, because it is a global setting and the rest
/// of the app has no rail to replace it with.
Future<void> setSystemVolumeUiShown(bool shown) async {
  try {
    await FlutterVolumeController.updateShowSystemUI(shown);
  } catch (error) {
    if (kDebugMode) debugPrint('system volume UI toggle failed: $error');
  }
}
