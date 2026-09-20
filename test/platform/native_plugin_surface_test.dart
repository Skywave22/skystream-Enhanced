/// What native code every platform build registers, pinned.
///
/// A dependency is added once, in `pubspec.yaml`, usually for one platform —
/// but it is bought for all five, and the bill is paid at **registration**, not
/// at use. `generated_plugin_registrant` constructs every registered plugin at
/// startup, so "no Dart code calls this" does not stop a plugin doing whatever
/// it likes the moment the app launches. Nothing else in this repo records what
/// each platform is carrying.
///
/// That is the mechanism behind both of the worst bugs this project has
/// shipped, and neither was visible to the rest of the suite:
///
///   * `screen_brightness` was added for the mobile player's touch rail. It
///     silently bought a Windows plugin that drives DDC/CI — I²C over the
///     display cable — at its registrar and again on `WM_CLOSE`, for a feature
///     `vlc_player_controls.dart` returns early from on desktop. Users reported
///     SkyStream resetting their monitor's brightness.
///   * `flutter_inappwebview` was added for the Cloudflare bypass. It silently
///     bought a Windows plugin whose constructor builds a WinRT dispatcher
///     queue, a Graphics.Capture probe, a hardware D3D11 device and a
///     compositor before any Dart runs — none of which this app ever uses.
///
/// This test is the ledger. It does not judge; it makes a change to the native
/// surface **impossible to make silently**. When it fails, the diff names the
/// plugin, and someone decides — on purpose, in the pull request — rather than
/// finding out on release day on a platform they cannot build.
///
/// Editing the expected sets is a normal part of adding a dependency. What is
/// not normal is editing them without reading what the new plugin does at
/// registration on the platform you do not build.
///
/// This runs on any host: `flutter pub get` resolves the full five-platform
/// graph regardless of which machine it runs on, and `flutter test` runs
/// `pub get` first, so the manifest is always fresh.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Plugins that compile and register native code, per platform.
///
/// Dart-only plugins are deliberately excluded: they register nothing and cost
/// nothing at startup. `flutter_torrent_server` is the in-repo example — it
/// declares `dartPluginClass` with no `pluginClass` on desktop, so it appears
/// in no registrant at all.
const Map<String, Set<String>> _expected = <String, Set<String>>{
  'android': {
    'android_file_picker',
    'background_downloader',
    'connectivity_plus',
    'device_info_plus',
    'dynamic_color',
    'flutter_displaymode',
    'flutter_inappwebview_android',
    'flutter_js_ng',
    'flutter_secure_storage',
    'flutter_torrent_server',
    'integration_test',
    'jni',
    'jni_flutter',
    'open_file_android',
    'package_info_plus',
    'permission_handler_android',
    'screen_brightness_android',
    'share_plus',
    'shared_preferences_android',
    'sqflite_android',
    'url_launcher_android',
    'vlc_player',
    'wakelock_plus',
  },
  'ios': {
    'background_downloader',
    'connectivity_plus',
    'device_info_plus',
    'file_picker_darwin',
    'flutter_inappwebview_ios',
    'flutter_js_ng',
    'flutter_secure_storage_darwin',
    'flutter_torrent_server',
    'integration_test',
    'open_file_ios',
    'package_info_plus',
    'permission_handler_apple',
    'screen_brightness_ios',
    'share_plus',
    'shared_preferences_foundation',
    'sqflite_darwin',
    'url_launcher_ios',
    'vlc_player',
    'wakelock_plus',
  },
  'macos': {
    'connectivity_plus',
    'device_info_plus',
    'dynamic_color',
    'file_picker_darwin',
    'flutter_inappwebview_macos',
    'flutter_js_ng',
    'flutter_secure_storage_darwin',
    'open_file_mac',
    'package_info_plus',
    // Desktop has no touch rail, so nothing reaches brightness here. Kept only
    // because macOS does not use DDC/CI for the built-in display the way the
    // Windows plugin does; revisit if that ever stops being true.
    'screen_brightness_macos',
    'screen_retriever_macos',
    'share_plus',
    'shared_preferences_foundation',
    'sqflite_darwin',
    'url_launcher_macos',
    'vlc_player',
    'wakelock_plus',
    'window_manager',
  },
  'linux': {
    'dynamic_color',
    'flutter_js_ng',
    'flutter_secure_storage_linux',
    'jni',
    'open_file_linux',
    'screen_retriever_linux',
    'url_launcher_linux',
    'vlc_player',
    'window_manager',
    // Deliberately absent: there is no flutter_inappwebview_linux in 6.1.5, so
    // Linux has no Cloudflare bypass. If one appears here, a dependency bump
    // has endorsed the 6.2.0-beta line, whose CMake hard-fails without five
    // apt packages CI does not install — that breaks the release artifact leg.
    // Decide in the PR, not on release day.
  },
  'windows': {
    'connectivity_plus',
    'dynamic_color',
    // The D3D11 device at registration. Kept on purpose: Windows Cloudflare
    // support depends on it. See the WebViewEnvironment work in
    // cloudflare_bypass.dart.
    'flutter_inappwebview_windows',
    'flutter_js_ng',
    'flutter_secure_storage_windows',
    'jni',
    // Dead code on Windows — every Permission.* call site is Platform.isAndroid
    // gated — but its registrar only builds method and event channels, so it is
    // not worth a stub package to remove.
    'permission_handler_windows',
    // OUR STUB, not upstream: packages/screen_brightness_windows is a no-op
    // registrar that keeps the real plugin's DDC/CI traffic off Windows. The
    // "Vendored Forks Resolve From Path" CI step asserts it still resolves from
    // the vendored path; this only asserts it is still the thing registering.
    'screen_brightness_windows',
    'screen_retriever_windows',
    'share_plus',
    'url_launcher_windows',
    'vlc_player',
    'window_manager',
  },
};

void main() {
  test('every platform registers exactly the native plugins we expect', () {
    final manifest = File('.flutter-plugins-dependencies');
    expect(
      manifest.existsSync(),
      isTrue,
      reason:
          'run from the package root; `flutter pub get` writes this file and '
          '`flutter test` runs pub get first, so it should always be here',
    );

    final plugins =
        (jsonDecode(manifest.readAsStringSync())
                as Map<String, dynamic>)['plugins']
            as Map<String, dynamic>;

    final problems = <String>[];

    for (final platform in _expected.keys) {
      final listed = (plugins[platform] as List<dynamic>? ?? <dynamic>[])
          .cast<Map<String, dynamic>>();
      final actual = listed
          .where((p) => p['native_build'] == true)
          .map((p) => p['name'] as String)
          .toSet();

      final added = actual.difference(_expected[platform]!);
      final removed = _expected[platform]!.difference(actual);

      for (final name in added) {
        problems.add(
          '$platform GAINED "$name". Something now compiles and registers '
          'native code on $platform. Read what it does at registration before '
          'adding it to the list — that is the step both shipped bugs skipped.',
        );
      }
      for (final name in removed) {
        problems.add(
          '$platform LOST "$name". If that was deliberate, delete it from the '
          'expected set. If not, a dependency or override has been dropped.',
        );
      }
    }

    expect(
      problems,
      isEmpty,
      reason:
          'The native plugin surface changed.\n\n${problems.join('\n\n')}\n\n'
          'This list is not a rule, it is a ledger: update it in the same '
          'commit as the dependency change, once you know what the plugin does '
          'when it registers.',
    );
  });
}
