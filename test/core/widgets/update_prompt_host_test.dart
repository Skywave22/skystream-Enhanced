/// When the app is allowed to interrupt with an update offer, and how often.
///
/// [UpdatePromptHost] owns two contracts. The offer is never made over the
/// player: it is held, not dropped, and made when the player is popped, using
/// the same `playerRouteIsOnTop` test the global toast layer stands down on
/// (lib/core/router/app_router.dart). And any exit from the dialog that is not
/// a failed download records the tag, so a release is offered once.
///
/// The storage here is in memory rather than the real Hive-backed
/// [StorageService]: a real box write cannot complete inside `flutter_test`'s
/// fake-async zone, so its write queue never drains and `Hive.close()`
/// deadlocks in the tear-down. That the preference survives a restart is
/// pinned separately, against a real box, in
/// test/core/storage/update_prompt_preference_test.dart.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skystream/core/data/models/github_release.dart';
import 'package:skystream/core/providers/update_provider.dart';
import 'package:skystream/core/router/app_router.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/core/widgets/update_dialog.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

GithubRelease _release(String tag) => GithubRelease(
  tagName: tag,
  htmlUrl: 'https://example.test/releases/$tag',
  body: 'Fixes and improvements.',
  assets: const <GithubAsset>[],
  prerelease: false,
);

class _MemoryStorageService extends StorageService {
  String? _tag;

  @override
  Future<void> setDeclinedUpdateTag(String tag) async => _tag = tag;

  @override
  String? getDeclinedUpdateTag() => _tag;
}

/// The real controller reaches for Dio and package_info the moment it is
/// built, and nothing here tests the GitHub call - only what the app does once
/// the answer is in.
class _StubUpdateController extends UpdateController {
  @override
  UpdateState build() => UpdateInitial();

  void emit(UpdateState next) => state = next;
}

void main() {
  late _MemoryStorageService storage;
  late ProviderContainer container;

  setUp(() {
    storage = _MemoryStorageService();
  });

  /// The production shape in miniature: a shell branch for the pages, the
  /// player as a top-level route beside it, and [UpdatePromptHost] wrapped
  /// around the router by `MaterialApp.router`'s builder, where `main.dart`
  /// mounts it.
  Future<GoRouter> pump(WidgetTester tester) async {
    final router = GoRouter(
      initialLocation: '/home',
      routes: <RouteBase>[
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) => shell,
          branches: <StatefulShellBranch>[
            StatefulShellBranch(
              routes: <RouteBase>[
                GoRoute(
                  path: '/home',
                  builder: (context, state) => const Scaffold(),
                ),
              ],
            ),
          ],
        ),
        GoRoute(
          path: kPlayerRoutePath,
          builder: (context, state) => const Scaffold(),
        ),
      ],
    );
    addTearDown(router.dispose);

    container = ProviderContainer(
      overrides: [
        appRouterProvider.overrideWithValue(router),
        storageServiceProvider.overrideWithValue(storage),
        updateControllerProvider.overrideWith(_StubUpdateController.new),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => UpdatePromptHost(child: child!),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  /// What a finished `UpdateController.checkForUpdates` does.
  void offer(String tag) {
    (container.read(updateControllerProvider.notifier) as _StubUpdateController)
        .emit(UpdateAvailable(_release(tag)));
  }

  testWidgets('off the player, an available release is offered straight away', (
    tester,
  ) async {
    await pump(tester);

    offer('v2.0.0');
    await tester.pumpAndSettle();

    expect(find.byType(UpdateDialog), findsOneWidget);
    expect(find.text('Update Available: v2.0.0'), findsOneWidget);

    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'over the player it is held, and made when the player is popped',
    (tester) async {
      final router = await pump(tester);

      unawaited(router.push(kPlayerRoutePath));
      await tester.pumpAndSettle();

      offer('v2.0.0');
      await tester.pumpAndSettle();

      // On a D-pad the modal takes the remote away from the transport
      // controls.
      expect(
        find.byType(UpdateDialog),
        findsNothing,
        reason: 'a modal landed on top of playing video',
      );

      // Held, not dropped: the moment the player is gone, the offer is made.
      router.pop();
      await tester.pumpAndSettle();
      expect(find.byType(UpdateDialog), findsOneWidget);

      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('"Later" is remembered, for that release only', (tester) async {
    await pump(tester);

    offer('v2.0.0');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();

    expect(storage.getDeclinedUpdateTag(), 'v2.0.0');

    // A relaunch is modelled by the same offer arriving again: the check runs
    // on every cold start and nothing stops it finding v2.0.0 a second time.
    offer('v2.0.0');
    await tester.pumpAndSettle();
    expect(
      find.byType(UpdateDialog),
      findsNothing,
      reason: 'the user already said Later to this release',
    );

    // The next release published is a new question, and gets asked.
    offer('v2.1.0');
    await tester.pumpAndSettle();
    expect(find.text('Update Available: v2.1.0'), findsOneWidget);

    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(storage.getDeclinedUpdateTag(), 'v2.1.0');
  });

  testWidgets('backing out of the dialog counts as Later', (tester) async {
    await pump(tester);

    offer('v2.0.0');
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDialog), findsOneWidget);

    // The Android back gesture and a D-pad Back both route out this way.
    // Choosing a different exit must not sidestep the record of being asked.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(UpdateDialog), findsNothing);
    expect(storage.getDeclinedUpdateTag(), 'v2.0.0');
  });

  testWidgets('a failed download is offered again, not written off', (
    tester,
  ) async {
    await pump(tester);

    offer('v2.0.0');
    await tester.pumpAndSettle();

    (container.read(updateControllerProvider.notifier) as _StubUpdateController)
        .emit(UpdateError('no route to host'));
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    // The release was accepted and the download failed. Recording that as a
    // refusal would mean the fix is never offered again.
    expect(storage.getDeclinedUpdateTag(), isNull);
  });
}
