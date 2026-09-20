import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/tmdb_config.dart';
import '../storage/storage_service.dart';
import '../network/doh_service.dart';
import '../logger/app_logger.dart';

part 'bootstrap_provider.g.dart';

/// Set once [quietDesktopBrightness] has told the plugin to stand down.
bool _desktopBrightnessQuieted = false;

@visibleForTesting
void debugResetDesktopBrightnessQuieted() => _desktopBrightnessQuieted = false;

/// Stops `screen_brightness` talking to the monitor on desktop.
///
/// The plugin's Windows side drives DDC/CI — I²C over the display link — to
/// read and write the monitor's own brightness. Its constructor probes once at
/// registration, and it then installs a window-proc delegate that re-probes on
/// `WM_SIZE` and `WM_ACTIVATEAPP` and *writes* on `WM_DESTROY`, `WM_CLOSE` and
/// deactivate, because the native `is_auto_reset_` defaults to true. Users have
/// reported SkyStream resetting their screen brightness on Windows; that is
/// this write, observed from the outside.
///
/// None of it buys anything on a desktop. The only caller of the brightness API
/// is the player's touch rail, and it returns early there
/// (`vlc_player_controls.dart`, `if (_isDesktop) return; // no touch rails`),
/// so the plugin's entire contribution on Windows is traffic on the display
/// link plus a leaked `PHYSICAL_MONITOR` handle per failed probe.
///
/// This is the cheap half of the fix: it stops every per-activation probe and
/// the pause-time write. It cannot stop the constructor's first probe — only
/// keeping the plugin out of the desktop build does that.
///
/// Mobile is deliberately untouched. There, auto-reset restores the system
/// brightness when the app leaves the foreground, which is what a viewer who
/// dimmed the screen for a film expects on the way out.
Future<void> quietDesktopBrightness() async {
  if (_desktopBrightnessQuieted) return;
  if (kIsWeb || !(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
    return;
  }
  // Latched before the await: a platform that cannot answer will not answer on
  // the second attempt either, and retrying is the behaviour being removed.
  _desktopBrightnessQuieted = true;
  try {
    await ScreenBrightness().setAutoReset(false);
  } catch (e) {
    // Expected on two of the three desktops, not a defect. Linux ships no
    // implementation of this plugin at all, and on Windows the vendored stub
    // in packages/screen_brightness_windows registers nothing - so both throw
    // MissingPluginException here on every launch. That is the benign case: a
    // platform with no plugin has no DDC/CI to stop. macOS is the one desktop
    // where this call does real work.
    talker.warning('Bootstrap: could not disable brightness auto-reset', e);
  }
}

@Riverpod(keepAlive: true)
class Bootstrap extends _$Bootstrap {
  @override
  Future<void> build() async {
    talker.info('Bootstrap: Starting initialization...');

    final storageService = ref.read(storageServiceProvider);

    try {
      await Future.wait([
        storageService.init().then(
          (_) => talker.info('Bootstrap: Storage initialized'),
        ),
        DohService.instance.init().then(
          (_) => talker.info('Bootstrap: DoH initialized'),
        ),
        if (Platform.isAndroid)
          FlutterDisplayMode.setHighRefreshRate().catchError((Object e) {
            talker.error('Bootstrap: Error setting high refresh rate', e);
          }),
        // Desktop only, and it swallows its own failures — see the function.
        quietDesktopBrightness(),
      ]);

      // Storage is open now, so TMDB keys the user saved in Settings or
      // Nuvio plugins screen can be mirrored into TmdbConfig's static cache.
      // This must happen before the first TMDB request (Stream/Explore fire on
      // their first build), which is why it lives here.
      final savedTmdbKey = storageService.getString('tmdb_api_key');
      if (savedTmdbKey != null && savedTmdbKey.trim().isNotEmpty) {
        TmdbConfig.setUserApiKey(savedTmdbKey);
        talker.info('Bootstrap: Loaded user TMDB API key from Settings');
      }

      try {
        final prefs = await SharedPreferences.getInstance();
        final savedNuvioKey = prefs.getString('nuvio_tmdb_api_key');
        if (savedNuvioKey != null && savedNuvioKey.trim().isNotEmpty) {
          TmdbConfig.setNuvioApiKey(savedNuvioKey);
          talker.info('Bootstrap: Loaded user TMDB API key from Nuvio');
        }
      } catch (_) {}

      talker.info('Bootstrap: Initialization complete');
    } catch (e, st) {
      talker.handle(e, st, 'Bootstrap: Critical initialization error');
      rethrow;
    }
  }
}
