/// The Cloudflare bypass must fail politely, and must never wedge itself.
///
/// Two defects are pinned here.
///
/// **Linux has no WebView at all.** `flutter_inappwebview` 6.1.5 endorses no
/// Linux implementation, and `HeadlessInAppWebView(...)` is constructed
/// *outside* the `try` in `_fetchViaWebView`, so the null-check TypeError
/// escapes `solveAndFetch` entirely and is caught by the catch-all in
/// `js_engine.dart`, which replies `{code: 0, body: ''}`. The provider's real
/// 403 — the one piece of information that would have explained the failure —
/// is destroyed by the recovery path. Declining up front is strictly better.
///
/// **A spawn that never returns holds the only slot forever.** The Windows
/// plugin logs and swallows a synchronous controller-creation failure, so its
/// completion handler never fires and `run()` never completes. The
/// `finally { _releaseSpawnSlot(); }` therefore never runs, and with
/// `_maxConcurrentSpawns = 1` every later solve in the process queues behind a
/// slot that will never be given back. One unhealthy spawn disables Cloudflare
/// until the app is restarted.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/network/cloudflare_bypass.dart';

/// The channel `HeadlessInAppWebView` drives.
const MethodChannel _headlessChannel = MethodChannel(
  'com.pichillilorenzo/flutter_headless_inappwebview',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<String> headlessCalls;

  setUp(() {
    headlessCalls = [];
    CloudflareBypass.debugResetPlatformProbe();
    CloudflareBypass.spawnTimeout = const Duration(milliseconds: 300);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_headlessChannel, null);
    CloudflareBypass.debugResetPlatformProbe();
    CloudflareBypass.debugResetSpawnTimeout();
  });

  /// Makes every headless call hang forever, the way a failed controller
  /// creation does on an unhealthy Windows machine.
  void stubHeadlessThatNeverAnswers() {
    messenger.setMockMethodCallHandler(_headlessChannel, (call) {
      headlessCalls.add(call.method);
      return Completer<Object?>().future; // never completes
    });
  }

  group('Linux', () {
    test('declines instead of throwing, so the real error survives', () async {
      CloudflareBypass.platformHasWebView = () => false;
      stubHeadlessThatNeverAnswers();

      final result = await CloudflareBypass.instance.solveAndFetch(
        'https://example.com/watch',
      );

      expect(result, isNull, reason: 'declining is the contract');
      expect(
        headlessCalls,
        isEmpty,
        reason: 'nothing may be spawned on a platform with no implementation',
      );
    });

    test('declining does not consume the spawn slot', () async {
      CloudflareBypass.platformHasWebView = () => false;

      for (var i = 0; i < 3; i++) {
        expect(
          await CloudflareBypass.instance.solveAndFetch('https://a$i.test/x'),
          isNull,
          reason: 'call $i',
        );
      }
    });
  });

  group('a spawn that cannot be constructed', () {
    // No InAppWebViewPlatform.instance is registered in a unit test, so the
    // HeadlessInAppWebView constructor asserts. That is the same shape as the
    // Linux failure and as a WebView2 runtime that will not initialise: the
    // constructor throws rather than returning. It used to sit above the try,
    // so the throw escaped solveAndFetch entirely.

    test('returns null instead of throwing out of solveAndFetch', () async {
      CloudflareBypass.platformHasWebView = () => true;

      final result = await CloudflareBypass.instance
          .solveAndFetch('https://ctor.test/one')
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => fail('solveAndFetch never returned'),
          );

      expect(
        result,
        isNull,
        reason:
            'an escaping throw is caught by the catch-all in js_engine.dart, '
            "which replies {code: 0, body: ''} and destroys the real status",
      );
    });

    test('hands the slot back, so the next solve still runs', () async {
      // The whole point: _maxConcurrentSpawns is 1, so a slot that is not
      // returned disables Cloudflare for the rest of the process.
      CloudflareBypass.platformHasWebView = () => true;

      await CloudflareBypass.instance
          .solveAndFetch('https://ctor.test/first')
          .timeout(const Duration(seconds: 30));

      final second = await CloudflareBypass.instance
          .solveAndFetch('https://ctor.test/second')
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => fail(
              'the second solve was queued behind a slot never released',
            ),
          );

      expect(second, isNull);
    });

    test('a hung native call is bounded too', () async {
      // Belt and braces for the case the constructor succeeds but run() never
      // completes, which is what the Windows plugin does on a synchronous
      // controller-creation failure.
      CloudflareBypass.platformHasWebView = () => true;
      stubHeadlessThatNeverAnswers();

      await CloudflareBypass.instance
          .solveAndFetch('https://hang.test/one')
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => fail('an unbounded run() wedged the solver'),
          );
    });
  });
}
