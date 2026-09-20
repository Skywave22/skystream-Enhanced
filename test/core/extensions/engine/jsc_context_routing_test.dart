@TestOn('mac-os')
library;

import 'package:flutter_js_ng/flutter_js.dart';
import 'package:flutter_test/flutter_test.dart';

/// JavaScriptCore runs on iOS and macOS only, and CI has no macOS test leg -
/// its only `flutter test` job is ubuntu-latest, which takes the QuickJS path.
/// So this file is gated to macOS and will not run in CI; without the gate it
/// would pass vacuously on Linux against an engine that has no such bug, which
/// is worse than not having it.
///
/// What it guards: JavaScriptCore dispatch used to go through a single static
/// slot holding the most recently constructed runtime. Dart statics are
/// per-isolate, so a second runtime in the same isolate rebound the first one's
/// bridge - and the Nuvio pool runs several scrapers per isolate. Two symptoms,
/// both reproduced before the fix: messages delivered to the wrong runtime's
/// handler, and a SIGSEGV when a surviving runtime sent a message after another
/// had been disposed and its context released.
///
/// `xhr: false` for the same reason JsBytecodeCompiler uses it: enableFetch()
/// pulls a polyfill through rootBundle and so needs ServicesBinding.
void main() {
  group('JavaScriptCore bridge routing', () {
    test('each runtime receives its own channel messages', () async {
      final a = getJavascriptRuntime(xhr: false);
      final b = getJavascriptRuntime(xhr: false);
      addTearDown(() {
        a.dispose();
        b.dispose();
      });

      final seen = <String>[];
      a.onMessage('probe', (dynamic args) {
        seen.add('a');
        return 'from-a';
      });
      b.onMessage('probe', (dynamic args) {
        seen.add('b');
        return 'from-b';
      });

      // Await between sends: a non-yielding scraper would pass this test
      // spuriously, because the cross-wire needs the second runtime to exist.
      final fromA = a.evaluate("sendMessage('probe', JSON.stringify({}))");
      await Future<void>.delayed(Duration.zero);
      final fromB = b.evaluate("sendMessage('probe', JSON.stringify({}))");
      await Future<void>.delayed(Duration.zero);

      expect(
        fromA.stringResult,
        contains('from-a'),
        reason: 'runtime A must reach its own handler, not the most recently '
            'constructed runtime',
      );
      expect(fromB.stringResult, contains('from-b'));
      expect(seen, <String>['a', 'b']);
    });

    test('a surviving runtime still works after another is disposed', () async {
      final survivor = getJavascriptRuntime(xhr: false);
      addTearDown(survivor.dispose);

      survivor.onMessage('probe', (dynamic args) => 'alive');

      final doomed = getJavascriptRuntime(xhr: false);
      doomed.onMessage('probe', (dynamic args) => 'doomed');
      doomed.dispose();

      // Before the fix this reached the released context and took the whole
      // process down with SIGSEGV, so a failure here may be a crash rather
      // than a failed expectation.
      final result =
          survivor.evaluate("sendMessage('probe', JSON.stringify({}))");
      expect(result.stringResult, contains('alive'));
    });
  });
}
