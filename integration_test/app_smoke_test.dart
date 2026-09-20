/// What the unit suite structurally cannot see.
///
/// `flutter test` runs on `flutter_tester`, where **no plugin is registered**.
/// So nothing a plugin does at registration — the moment this project's two
/// worst bugs happened — is observable there, and both compiled cleanly in CI:
///
///   * `screen_brightness_windows` issued DDC/CI (I²C over the display cable)
///     to the monitor's firmware from its constructor, and wrote brightness
///     back on every `WM_CLOSE`. Users reported SkyStream resetting their
///     screen brightness.
///   * WebView2 was handed its default user-data folder, `<exe_dir>\WebView2`,
///     which on an installed build is inside `C:\Program Files` and unwritable
///     to a standard user — so the Cloudflare bypass may never have worked in
///     the shipped Windows artifact.
///
/// These run against a real engine with real plugins registered. They are
/// deliberately few, fast and offline: the job is to catch a native failure at
/// startup on a real platform, not to re-test behaviour the unit suite already
/// covers. Nothing here touches the network.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:skystream/core/providers/bootstrap_provider.dart'
    show debugResetDesktopBrightnessQuieted, quietDesktopBrightness;

bool get _isDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the app support directory exists and is writable', (
    tester,
  ) async {
    final dir = await getApplicationSupportDirectory();
    expect(dir.existsSync(), isTrue, reason: 'no app support directory');

    // The assertion that would have caught the Program Files bug. Everything
    // the app persists - Hive boxes, logs, the WebView2 user-data folder -
    // depends on this being writable by the user running the app.
    final probe = File(p.join(dir.path, '.write_probe'));
    addTearDown(() {
      if (probe.existsSync()) probe.deleteSync();
    });

    probe.writeAsStringSync('ok');
    expect(
      probe.readAsStringSync(),
      'ok',
      reason:
          'app support is not writable: ${dir.path}. On Windows this is what '
          'sends WebView2 back to <exe_dir>\\WebView2 inside Program Files.',
    );
  });

  testWidgets('the desktop startup brightness call is harmless', (
    tester,
  ) async {
    if (!_isDesktop) {
      // Mobile legitimately keeps auto-reset on: the player's touch rail dims
      // the screen and the system brightness must come back afterwards.
      return;
    }

    // What this does and does not prove. It cannot see the regression it
    // sounds like it guards — that the real `screen_brightness_windows` has
    // come back and is driving DDC/CI from its registrar — because that is
    // native C++ running before any Dart, with no channel traffic to observe
    // and no API to enumerate registered plugins. The native surface is pinned
    // where it is actually visible: `test/platform/native_plugin_surface_test`
    // reads the resolved plugin manifest, and CI's "Vendored Forks Resolve
    // From Path" step asserts the stub is what resolves.
    //
    // What is only observable here, on a real engine with real plugins, is
    // that the startup call itself is survivable on every desktop: it succeeds
    // on macOS, and on Windows and Linux it throws MissingPluginException —
    // the stub and the absent plugin respectively — which `main()` must
    // swallow rather than take the launch down with it.
    //
    // Safe to call even if the real Windows plugin were restored: setAutoReset
    // only assigns the native `is_auto_reset_` flag; it issues no DDC/CI.
    debugResetDesktopBrightnessQuieted();
    addTearDown(debugResetDesktopBrightnessQuieted);

    await expectLater(
      quietDesktopBrightness().timeout(
        // 60s, not something tighter. This is the one test here that waits on
        // a REAL plugin through a real method channel, on a cold app on a
        // possibly-loaded CI runner - the first channel call of a process can
        // be far slower than a warm one. A tight bound here buys nothing (the
        // app fires this unawaited, so it is never on a user's critical path)
        // and costs a flaky red build. It is a hang detector, not a budget.
        const Duration(seconds: 60),
        onTimeout: () => fail(
          'quietDesktopBrightness never settled. main() fires it unawaited so '
          'a hang cannot block launch, but a call that never returns still '
          'means the plugin is wedged and auto-reset was never turned off.',
        ),
      ),
      completes,
    );
  });

  testWidgets('a WebView2 user-data folder can be created where we put it', (
    tester,
  ) async {
    if (kIsWeb || !Platform.isWindows) return;

    // Not WebViewEnvironment.create itself - that would spawn a real
    // msedgewebview2.exe in CI. The failure mode being pinned is the folder:
    // WebView2 could not create its store because the app had pointed it at an
    // unwritable directory.
    final dir = await getApplicationSupportDirectory();
    final folder = Directory(p.join(dir.path, 'webview2'));

    // The integration runner resolves the same app-support directory as the
    // shipped app, so this is a real user's live WebView2 profile — their
    // cf_clearance cookies, their browser cache. Clean up only what this test
    // created: the probe file always, the folder itself only if it was not
    // already there. Never `deleteSync(recursive: true)` on a path the app
    // owns at runtime.
    final preexisting = folder.existsSync();
    final probe = File(p.join(folder.path, '.write_probe'));
    addTearDown(() {
      if (probe.existsSync()) probe.deleteSync();
      // Non-recursive and only when empty: if anything else ended up in
      // there, leaving it is the correct outcome.
      if (!preexisting && folder.existsSync() && folder.listSync().isEmpty) {
        folder.deleteSync();
      }
    });

    if (!preexisting) folder.createSync(recursive: true);
    probe.writeAsStringSync('ok');

    expect(probe.existsSync(), isTrue);
    expect(
      folder.path.toLowerCase(),
      isNot(contains('program files')),
      reason:
          'the whole point of the WebViewEnvironment change is that WebView2 '
          'no longer keeps its store inside the installation directory',
    );
  });
}
