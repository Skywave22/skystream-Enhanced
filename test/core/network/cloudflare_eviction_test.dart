/// Which cached WebView the solver is allowed to tear down.
///
/// The bug this pins: `_maxCachedWebViews` is 2, and every solve for a host
/// that is not already cached evicts to make room. The cached-reuse path in
/// `solveAndFetch` does NOT register in `_activeByHost` — that guards fresh
/// solves only — so a caller can sit inside `navigate()` for up to
/// `_navTimeout` with nothing marking that view as busy. Eviction used to take
/// `_hostWebViews.keys.first` unconditionally, which meant it could run
/// `_headless.dispose()` against a WebView with a live platform-channel call
/// in flight.
///
/// On Windows that destroys the `ICoreWebView2` under an in-flight `loadUrl`
/// or `evaluateJavascript`. It faults in-process, and there is no Dart
/// exception for `navigate()`'s `catch (e)` to swallow — the app simply dies.
/// It gets likelier the more distinct hosts are browsed, because each new host
/// forces an eviction: the reported symptom is crashing while navigating.
///
/// This tests the policy, not the whole flow: a real `HeadlessInAppWebView`
/// cannot be constructed under `flutter_tester`, so the end-to-end race is not
/// reachable here. What is reachable — and what regressed — is the choice of
/// victim.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/network/cloudflare_bypass.dart';

/// `(host, inUse)` in insertion order, which is age order.
List<MapEntry<String, bool>> views(Map<String, bool> inUseByHost) =>
    inUseByHost.entries.toList();

void main() {
  test('evicts the oldest view when nothing is in use', () {
    expect(
      CloudflareBypass.pickEvictionVictim(
        views({'a.test': false, 'b.test': false}),
      ),
      'a.test',
      reason: 'insertion order is age order, so the first entry is the oldest',
    );
  });

  test('never evicts a view that is mid-navigation', () {
    expect(
      CloudflareBypass.pickEvictionVictim(
        views({'busy.test': true, 'idle.test': false}),
      ),
      'idle.test',
      reason:
          'busy.test is older, but disposing it would destroy its native '
          'controller under a live platform-channel call',
    );
  });

  test('skips several busy views to reach an idle one', () {
    expect(
      CloudflareBypass.pickEvictionVictim(
        views({'b1.test': true, 'b2.test': true, 'free.test': false}),
      ),
      'free.test',
    );
  });

  test('falls back to the oldest when every cached view is in use', () {
    // Deliberately NOT null. Refusing to evict looks safer but removes the
    // ceiling: the caller spawns regardless, so the cache would grow without
    // bound, and on Windows each extra view is another msedgewebview2.exe on
    // the same shared GPU memory. Evicting a busy view is safe now because
    // dispose() defers the native teardown and unlists the view immediately.
    expect(
      CloudflareBypass.pickEvictionVictim(
        views({'x.test': true, 'y.test': true}),
      ),
      'x.test',
    );
  });

  test('prefers an idle view over an older busy one', () {
    // The ordering rule that keeps the common case undisturbed.
    expect(
      CloudflareBypass.pickEvictionVictim(
        views({'old.busy': true, 'new.idle': false}),
      ),
      'new.idle',
    );
  });

  test('an empty cache has nothing to evict', () {
    expect(CloudflareBypass.pickEvictionVictim(views({})), isNull);
  });
}
