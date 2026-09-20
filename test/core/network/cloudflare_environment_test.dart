/// Where WebView2 is allowed to keep its user-data folder on Windows.
///
/// The app creates no `WebViewEnvironment`, so WebView2 falls back to its
/// default: `<exe_dir>\WebView2`. `windows/packaging/exe/setup.iss` installs to
/// `{autopf}\SkyStream` — Program Files — with no `PrivilegesRequired` line, so
/// a standard user cannot write there and environment creation fails. If that
/// is live, the Cloudflare bypass has never worked in the shipped Windows
/// artifact, only under `flutter run` from a writable source tree.
///
/// Three properties are pinned here, and the third is the one that silently
/// undoes the other two:
///
/// * The environment is **Windows-only**. Nothing else has the concept.
/// * It is created **lazily and once**. `WebViewEnvironment.create` also builds
///   a hidden `CoreWebView2Controller` (webview_environment.cpp:69-75), so an
///   eager call would put an `msedgewebview2.exe` on every Windows launch —
///   the exact footprint being removed.
/// * The **cookie manager shares it**. `CookieManager.instance()` with no
///   environment resolves a *different* default user-data folder, so cookie
///   reads come back empty and `_injectCfCookies` returns at its
///   `if (webCookies.isEmpty)` guard — the bypass appears to work and then
///   quietly never hands Dio a cookie.
///
/// The creation itself is injected: `WebViewEnvironment.create` dispatches to a
/// platform implementation that is not registered in a unit test, so the real
/// call is unreachable off Windows. What is under test is the orchestration —
/// when it is called, how often, with what, and what happens when it fails.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/network/cloudflare_bypass.dart';

const MethodChannel _pathProvider = MethodChannel(
  'plugins.flutter.io/path_provider',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Every user-data folder the solver asked an environment to be built on.
  late List<String> folders;

  setUp(() {
    folders = [];
    // Pinned, not reset to the default. The real probe is
    // `kIsWeb || !Platform.isLinux`, so leaving it alone makes every test
    // below that drives a solve depend on the OS the suite happens to run on:
    // solveAndFetch declines at its `platformHasWebView` guard before it ever
    // reaches the environment build, so `folders` comes back empty on a Linux
    // CI runner and populated on a macOS laptop. The orchestration is what is
    // under test here (see the library doc), not which platforms have a
    // WebView -- that contract is covered by the `Linux` group in
    // cloudflare_bypass_test.dart, which pins this probe false on purpose.
    CloudflareBypass.platformHasWebView = () => true;
    CloudflareBypass.debugResetEnvironment();
    CloudflareBypass.spawnTimeout = const Duration(milliseconds: 200);

    messenger.setMockMethodCallHandler(
      _pathProvider,
      (call) async => r'C:\Users\someone\AppData\Roaming\dev.akash.skystream',
    );
    CloudflareBypass.createEnvironment = (folder) async {
      folders.add(folder);
      return null; // a real WebViewEnvironment cannot be built in a test
    };
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_pathProvider, null);
    CloudflareBypass.debugResetPlatformProbe();
    CloudflareBypass.debugResetEnvironment();
    CloudflareBypass.debugResetSpawnTimeout();
  });

  test('nothing is built at rest — it is lazy, not eager', () {
    CloudflareBypass.needsWebViewEnvironment = () => true;

    expect(
      folders,
      isEmpty,
      reason:
          'creating an environment also creates a hidden WebView2 controller, '
          'so doing it at startup puts a browser process on every launch',
    );
  });

  test('a solve builds one, off the install directory', () async {
    CloudflareBypass.needsWebViewEnvironment = () => true;

    await CloudflareBypass.instance.solveAndFetch('https://cf.test/a');

    expect(folders, hasLength(1));
    expect(
      folders.single,
      isNot(contains('Program Files')),
      reason: 'getting off the unwritable install directory is the whole point',
    );
    expect(
      folders.single,
      contains('webview2'),
      reason: 'kept in its own subfolder, not loose in app support',
    );
  });

  test('it is built once, however many solves run', () async {
    CloudflareBypass.needsWebViewEnvironment = () => true;

    await CloudflareBypass.instance.solveAndFetch('https://cf.test/one');
    await CloudflareBypass.instance.solveAndFetch('https://cf.test/two');
    await CloudflareBypass.instance.solveAndFetch('https://cf.test/three');

    expect(
      folders,
      hasLength(1),
      reason: 'a second environment would mean a second user-data folder',
    );
  });

  test('platforms without the concept never build one', () async {
    CloudflareBypass.needsWebViewEnvironment = () => false;

    await CloudflareBypass.instance.solveAndFetch('https://cf.test/b');

    expect(folders, isEmpty);
  });

  test('the cookie manager reuses it rather than building a second', () async {
    // This is the silent killer: two environments means two user-data folders,
    // so the solver writes cf_clearance into one and the cookie read looks in
    // the other and finds nothing.
    CloudflareBypass.needsWebViewEnvironment = () => true;

    await CloudflareBypass.instance.solveAndFetch('https://cf.test/d');
    await CloudflareBypass.instance.cookieEnvironment();
    await CloudflareBypass.instance.cookieEnvironment();

    expect(folders, hasLength(1));
  });

  test('a caller arriving mid-creation waits for the result', () async {
    // The hole a `bool attempted` latch would leave. The latch is set before
    // the await, so a second caller arriving while the first is still building
    // sees "attempted" with the value still null and proceeds with *no*
    // environment — on Windows that is a cookie read against a different
    // user-data folder, which comes back empty and kills injection silently.
    // Caching the Future means everyone awaits the same attempt.
    CloudflareBypass.needsWebViewEnvironment = () => true;
    final building = Completer<void>();
    CloudflareBypass.createEnvironment = (folder) async {
      folders.add(folder);
      await building.future;
      return null;
    };

    final first = CloudflareBypass.instance.cookieEnvironment();
    var secondSettled = false;
    final second = CloudflareBypass.instance.cookieEnvironment().whenComplete(
      () => secondSettled = true,
    );

    // Drain microtasks and one timer tick: enough for a short-circuit return
    // to have landed, not enough for a real build to have finished.
    await Future<void>.delayed(Duration.zero);
    expect(
      secondSettled,
      isFalse,
      reason:
          'the second caller returned before creation finished, so it got a '
          'latch rather than an environment',
    );

    building.complete();
    await Future.wait<void>([first, second]);

    expect(folders, hasLength(1), reason: 'both callers shared one build');
  });

  test('a failed build degrades instead of throwing', () async {
    CloudflareBypass.needsWebViewEnvironment = () => true;
    CloudflareBypass.createEnvironment = (folder) async {
      folders.add(folder);
      throw PlatformException(code: 'no', message: 'folder not writable');
    };

    // An escaping error here is the F3 failure mode again, where the recovery
    // path destroys the provider's real response.
    final result = await CloudflareBypass.instance
        .solveAndFetch('https://cf.test/c')
        .timeout(
          const Duration(seconds: 30),
          onTimeout: () => fail('solveAndFetch hung on a failed environment'),
        );

    expect(result, isNull);
  });

  test('a failed build is not retried on every solve', () async {
    CloudflareBypass.needsWebViewEnvironment = () => true;
    CloudflareBypass.createEnvironment = (folder) async {
      folders.add(folder);
      throw PlatformException(code: 'no', message: 'folder not writable');
    };

    await CloudflareBypass.instance.solveAndFetch('https://cf.test/e');
    await CloudflareBypass.instance.solveAndFetch('https://cf.test/f');

    expect(
      folders,
      hasLength(1),
      reason:
          'an unwritable folder will still be unwritable next time; retrying '
          'is the behaviour being removed everywhere else in this file',
    );
  });
}
