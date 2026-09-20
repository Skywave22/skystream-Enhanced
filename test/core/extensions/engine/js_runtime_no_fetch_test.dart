import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// No JavaScript runtime in the engine may ask for the fetch polyfill.
///
/// `getJavascriptRuntime()` defaults to `xhr: true`, and that calls
/// `enableFetch()`, which reads `packages/flutter_js_ng/assets/js/fetch.js`
/// through `rootBundle` - so it needs `ServicesBinding.instance`. None of these
/// runtimes can promise one: the worker builds its runtime inside a background
/// isolate, and the bytecode compiler is reached from provider init, which has
/// no binding in a plain `test()`. Every plugin network call goes through the
/// engine's own HTTP bridge, so the polyfill buys nothing either way.
///
/// Asserted as source text because the failure is platform-shaped and cannot be
/// reproduced on this machine: `JsBytecodeCompiler.supported` is false on macOS
/// and iOS, so the compiler returns before building a runtime at all, and the
/// binding error only ever appears on Android, Windows and Linux. A behavioural
/// test here would pass on a developer's Mac and go on failing in CI, which is
/// the exact hole this closes.
void main() {
  const dir = 'lib/core/extensions/engine';

  test('every engine runtime is built with xhr: false', () {
    final offenders = <String>[];

    for (final entity in Directory(dir).listSync().whereType<File>()) {
      if (!entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();

      // Each call, with its arguments, up to the closing paren of the call.
      for (final match
          in RegExp(r'getJavascriptRuntime\s*\(([^;]*?)\)\s*;', dotAll: true)
              .allMatches(source)) {
        final args = match.group(1)!;
        if (!args.contains('xhr: false')) {
          offenders.add('${entity.path}: getJavascriptRuntime($args)');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These build a runtime that loads the fetch polyfill through '
          'rootBundle, which throws "Binding has not yet been initialized" '
          'wherever there is no ServicesBinding. Pass xhr: false.',
    );
  });

  test('the rule covers something, so it cannot pass by finding nothing', () {
    // A guard on the guard: if the call ever moves or is renamed, the loop
    // above would sweep an empty set and report success.
    final calls = Directory(dir)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .map((f) => RegExp('getJavascriptRuntime').allMatches(
              f.readAsStringSync(),
            ).length)
        .fold<int>(0, (a, b) => a + b);

    expect(calls, greaterThanOrEqualTo(2),
        reason: 'Expected the worker and the bytecode compiler at least.');
  });
}
