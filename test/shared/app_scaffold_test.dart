/// The shell's television cursor, and the two things it must not break.
///
/// Android TV boxes and Fire sticks report a pointer whether or not one is
/// attached, and trackpad remotes move a real one, so a stationary arrow
/// parked in the middle of a 3 m screen is reachable on shipping hardware -
/// and it is the clearest possible tell that an app was not built for a
/// television. None of Netflix, Prime Video or YouTube shows one.
///
/// The shell already owned a [Listener] for pointer events (it is how the
/// focus-highlight mode learns that the D-pad has stopped driving), so the
/// clock hangs off that. Two hazards come with it, and both are pinned below:
///
/// 1. HIT TESTING. A cursor layer that swallowed hits would make the whole
///    shell unclickable, which is a far worse bug than the one being fixed.
/// 2. THE PLAYER. The player is a *top-level* route with a cursor auto-hide of
///    its own (vlc_player_controls.dart), and it asks for [MouseCursor.defer]
///    while its bars are up. `defer` resolves *outwards*, so a shell still
///    holding [SystemMouseCursors.none] underneath would hide the pointer out
///    from under visible player chrome. The shell stands down while it is not
///    the current route, so the two can never disagree.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/core/router/app_router.dart' show kPlayerRoutePath;
import 'package:skystream/features/settings/presentation/general_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:skystream/shared/widgets/app_scaffold.dart';

/// A 1080p television: 960x540 dp at devicePixelRatio 2.
const Size _tvPhysical = Size(1920, 1080);

/// Long enough for the clock to have fired, whatever frame it lands on.
const Duration _pastTheClock = Duration(seconds: 4);

/// A full-bleed page that reports every tap that reaches it, so a swallowed
/// one shows up as an absence rather than being inferred.
class _TapProbe extends StatelessWidget {
  const _TapProbe({required this.taps});

  final List<String> taps;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapDown: (details) => taps.add('${details.globalPosition}'),
    child: const SizedBox.expand(),
  );
}

/// Stands in for the player route: a top-level page, opaque, carrying a
/// [MouseRegion] that *defers* - which is exactly what the real player asks
/// for while its bars are visible.
class _DeferringPlayerPage extends StatelessWidget {
  const _DeferringPlayerPage();

  @override
  Widget build(BuildContext context) => const MouseRegion(
    cursor: MouseCursor.defer,
    child: ColoredBox(color: Color(0xFF000000), child: SizedBox.expand()),
  );
}

void main() {
  late List<String> taps;

  /// Every `activateSystemCursor` the framework sends to the platform, in
  /// order. This is the real question - what the *system* is asked to draw -
  /// rather than what one widget in the tree happens to hold, so it exercises
  /// the whole `defer` resolution chain.
  late List<String> kinds;

  setUp(() {
    taps = <String>[];
    kinds = <String>[];
  });

  void watchTheCursor(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.mouseCursor,
      (call) async {
        if (call.method == 'activateSystemCursor') {
          kinds.add(
            (call.arguments as Map<Object?, Object?>)['kind']! as String,
          );
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.mouseCursor,
        null,
      ),
    );
  }

  /// The production shape in miniature: the five shell branches under
  /// [AppScaffold], and the player beside them as a top-level route.
  Future<GoRouter> pumpShell(
    WidgetTester tester, {
    required bool isTv,
    Size physicalSize = _tvPhysical,
  }) async {
    tester.view.physicalSize = physicalSize;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) =>
              AppScaffold(navigationShell: shell),
          branches: [
            for (final path in const [
              '/home',
              '/search',
              '/explore',
              '/library',
              '/settings',
            ])
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: path,
                    builder: (_, _) => _TapProbe(taps: taps),
                  ),
                ],
              ),
          ],
        ),
        GoRoute(
          path: kPlayerRoutePath,
          builder: (_, _) => const _DeferringPlayerPage(),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceProfileProvider.overrideWithValue(
            AsyncValue.data(DeviceProfile(isTv: isTv, isTablet: !isTv)),
          ),
          generalSettingsProvider.overrideWithValue(const GeneralSettings()),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  /// A mouse sitting in the middle of the content area, the way a trackpad
  /// remote leaves one.
  Future<TestGesture> parkPointer(WidgetTester tester) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(find.byType(_TapProbe)));
    await tester.pump();
    return mouse;
  }

  /// What the shell's own cursor layer is asking for right now. Read through
  /// the key so a stray [MouseRegion] elsewhere in the shell (the sidebar has
  /// several) cannot be mistaken for it.
  MouseCursor shellCursor(WidgetTester tester) => tester
      .widget<MouseRegion>(find.byKey(kTvCursorRegionKey, skipOffstage: false))
      .cursor;

  /// Runs the clock out. Also the reason a test can end here: a live clock is
  /// a pending timer, and flutter_test checks for those before tear-downs run.
  Future<void> runTheClockOut(WidgetTester tester) async {
    await tester.pump(_pastTheClock);
    await tester.pump();
  }

  group('the television cursor', () {
    testWidgets('a pointer that stops moving loses its cursor, and the shell '
        'stays clickable without it', (tester) async {
      watchTheCursor(tester);
      await pumpShell(tester, isTv: true);
      final mouse = await parkPointer(tester);

      expect(kinds.last, 'basic', reason: 'a pointer in use keeps its cursor');
      expect(shellCursor(tester), MouseCursor.defer);

      await runTheClockOut(tester);

      expect(shellCursor(tester), SystemMouseCursors.none);
      expect(kinds.last, 'none', reason: 'the platform was told to drop it');

      // The whole risk of a cursor layer: it must not be a hit target of its
      // own. A press with the cursor already hidden still has to land.
      await mouse.down(tester.getCenter(find.byType(_TapProbe)));
      await mouse.up();
      await tester.pump();
      expect(taps, hasLength(1));

      await runTheClockOut(tester);
    });

    testWidgets('the next movement brings it straight back', (tester) async {
      watchTheCursor(tester);
      await pumpShell(tester, isTv: true);
      final mouse = await parkPointer(tester);
      await runTheClockOut(tester);
      expect(kinds.last, 'none');

      await mouse.moveTo(
        tester.getCenter(find.byType(_TapProbe)) + const Offset(40, 0),
      );
      await tester.pump();

      expect(shellCursor(tester), MouseCursor.defer);
      expect(kinds.last, 'basic', reason: 'no waiting for a frame or a tap');

      await runTheClockOut(tester);
    });

    testWidgets('something animating under a stationary pointer is not '
        'movement', (tester) async {
      watchTheCursor(tester);
      await pumpShell(tester, isTv: true);
      final mouse = await parkPointer(tester);
      final parked = tester.getCenter(find.byType(_TapProbe));
      await runTheClockOut(tester);
      expect(kinds.last, 'none');

      // A hover re-delivered at an unchanged position: what the framework
      // sends when the widget under a still pointer changes. A ten-foot home
      // screen is carousels doing exactly that, so a clock re-armed by this
      // would never fire again.
      await mouse.moveTo(parked);
      await tester.pump();

      expect(
        shellCursor(tester),
        SystemMouseCursors.none,
        reason: 'the pointer did not move, so nothing woke up',
      );
      expect(kinds.last, 'none');
    });

    testWidgets('a click that arrives without a nudge brings it back', (
      tester,
    ) async {
      watchTheCursor(tester);
      await pumpShell(tester, isTv: true);
      final mouse = await parkPointer(tester);
      final parked = tester.getCenter(find.byType(_TapProbe));
      await runTheClockOut(tester);
      expect(kinds.last, 'none');

      // Same position as the last hover - a mouse can be clicked without
      // being moved, and that is unambiguously the pointer being used.
      await mouse.down(parked);
      await tester.pump();

      expect(shellCursor(tester), MouseCursor.defer);
      expect(kinds.last, 'basic');

      await mouse.up();
      await runTheClockOut(tester);
    });

    testWidgets('off a television the cursor is left alone', (tester) async {
      watchTheCursor(tester);
      // A tablet or a desktop window: same shell branch, same Listener, but a
      // mouse on a desk that no OS takes away, and a user who would read a
      // vanished cursor as a hang.
      await pumpShell(tester, isTv: false);
      await parkPointer(tester);

      await runTheClockOut(tester);

      expect(shellCursor(tester), MouseCursor.defer);
      expect(kinds.last, 'basic');
    });

    testWidgets('the shell lets go of the cursor while the player owns the '
        'screen', (tester) async {
      watchTheCursor(tester);
      final router = await pumpShell(tester, isTv: true);
      await parkPointer(tester);
      await runTheClockOut(tester);
      expect(shellCursor(tester), SystemMouseCursors.none);

      unawaited(router.push(kPlayerRoutePath));
      await tester.pumpAndSettle();

      // The player's own region defers while its bars are up, and `defer`
      // resolves outwards to whatever the shell is holding. So the shell has
      // to be holding nothing, for the whole time the player is up - not
      // merely be off the hit path, which is an accident of Overlay ordering
      // that a transparent player route or a mid-transition frame undoes.
      expect(
        shellCursor(tester),
        MouseCursor.defer,
        reason: 'the player, not the shell, decides the cursor now',
      );

      // And the clock is not left ticking under it: a shell that rebuilt
      // itself mid-playback would be rebuilding five branch Navigators.
      await tester.pump(_pastTheClock);
      expect(shellCursor(tester), MouseCursor.defer);

      router.pop();
      await tester.pumpAndSettle();
    });
  });
}
