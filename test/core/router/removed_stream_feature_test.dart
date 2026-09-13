import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/router/app_router.dart';

/// `lib/features/stream/` was ~1,700 lines of a browse-and-play feature -
/// a provider, an aggregator, a picker and a `PlayerRoute` launch path - that
/// nothing could reach. The `/stream` route had already been taken out of the
/// router, so it was not reachable by tapping and not reachable by deep link
/// either; `kShellBranchRoutes` exists to migrate a saved preference that
/// still points there.
///
/// Dead code that *looks* live is worse than dead code that looks dead:
/// somebody maintains it, translates it and fixes bugs in it. It is deleted.
/// The point of this test is that reading the tree cannot tell you the
/// feature was ever unreachable, so the fact has to be written down somewhere
/// that fails.
void main() {
  test('the stream feature directory stays deleted', () {
    expect(
      Directory('lib').existsSync(),
      isTrue,
      reason: 'run this from the package root',
    );
    expect(
      Directory('lib/features/stream').existsSync(),
      isFalse,
      reason:
          'lib/features/stream was unreachable dead code; if it is coming '
          'back it needs a route, and this test should be deleted with intent',
    );
  });

  test('nothing in lib/ still references it', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      if (source.contains('features/stream/') ||
          source.contains('stream_browser_provider') ||
          source.contains('streamBrowserProvider')) {
        offenders.add(entity.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'a dangling import or a ref.invalidate of a provider nobody watches',
    );
  });

  test('/stream is not a route, so no deep link can reach it', () {
    expect(kShellBranchRoutes, isNot(contains('/stream')));
    expect(
      File('lib/core/router/app_router.dart').readAsStringSync(),
      isNot(contains("'/stream'")),
    );
  });
}
