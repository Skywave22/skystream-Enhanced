/// `JsBytecodeCompiler.settle()` exists so a test can await compiles it never
/// started: [JsBasedProvider] fires `compile().ignore()` on purpose, and that
/// detached write used to outlive the test that triggered it and land after
/// its temporary directory had been deleted.
///
/// What is pinned here is the bookkeeping, because its failure mode is the
/// expensive one. `settle()` loops until the in-flight list empties, so an
/// entry that is added and never removed does not fail a test -- it hangs the
/// suite until the CI job's own timeout, with nothing in the output to say
/// why.
///
/// On macOS `supported` is false and every compile short-circuits before it
/// touches the filesystem, so this only exercises the tracking there. That is
/// the half that can hang; the compile itself is covered on Linux and Windows
/// CI, which is also the only place the original race was visible.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/extensions/engine/js_bytecode_compiler.dart';

void main() {
  test('settle() drains, and drains again once empty', () async {
    final dir = await Directory.systemTemp.createTemp('settle_drain');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    for (var i = 0; i < 8; i++) {
      JsBytecodeCompiler.compile(
        '(function(){})',
        '${dir.path}/p$i.qbc',
      ).ignore();
    }

    await JsBytecodeCompiler.settle().timeout(
      const Duration(seconds: 10),
      onTimeout: () => fail('settle() hung: the in-flight list never drained'),
    );
    // A second call must not wait on entries the first one removed.
    await JsBytecodeCompiler.settle().timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail('settle() hung on an already-drained list'),
    );
  });

  test('a compile that fails is still removed from the list', () async {
    // The real shape of the race: the directory is gone before the write.
    final dir = await Directory.systemTemp.createTemp('settle_failure');
    final path = '${dir.path}/gone.qbc';
    await dir.delete(recursive: true);

    JsBytecodeCompiler.compile('(function(){})', path).ignore();

    await JsBytecodeCompiler.settle().timeout(
      const Duration(seconds: 10),
      onTimeout: () =>
          fail('a failed compile stayed in the list and hung settle()'),
    );
  });
}
