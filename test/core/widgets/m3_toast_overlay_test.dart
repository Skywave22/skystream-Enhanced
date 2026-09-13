/// The global toast layer, and the one place it must not be.
///
/// [M3ToastOverlay] is mounted in `MaterialApp.router`'s builder
/// (lib/main.dart), i.e. *around* the router's Navigator. The player is a
/// top-level route rather than a shell child, so it is built by that same root
/// Navigator - underneath the toast layer. The card is a live `InkWell` inside
/// a `MouseRegion` and the `IgnorePointer(ignoring: false)` above it is a
/// no-op, so on a landscape phone a toast fired by a background job lands on
/// the player's bottom bar and eats the tap meant for the control below it.
/// Measured at 844x390 dp: the card occupies (518, 318)-(820, 366) while the
/// bottom bar's speed, volume and resize buttons sit at (620..824, 317..377).
///
/// Hence the contract here: the global layer stands down for as long as the
/// player is the top route, and comes straight back when it is popped. The
/// player has its own transient layer (`TransientOverlay`) for its own
/// messages, so nothing is lost.
///
/// The second contract, further down: *where* the card lands is a question
/// about the window, not about the machine. It used to be
/// `isDesktopOS || isTv || width >= 720`, and the two device clauses could
/// only ever disagree with the width in one direction - a desktop window
/// dragged under 720 dp still got the corner treatment, in a window with no
/// corner to spare. A television never needed a clause: it is 960 dp wide.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/core/router/app_router.dart';
import 'package:skystream/core/services/notification_service.dart';
import 'package:skystream/core/widgets/m3_toast_overlay.dart';

/// A phone held sideways, which is the only shape the player runs at on touch.
const Size _phone = Size(844, 390);

/// A page that reports every tap that reaches it, so a swallowed one is
/// visible as an absence rather than inferred.
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

void main() {
  late NotificationService service;
  late List<String> taps;

  setUp(() {
    service = NotificationService();
    taps = <String>[];
  });

  /// The production shape in miniature: a shell branch for the pages, the
  /// player as a *top-level* route beside it, and the toast layer wrapped
  /// around the router by `MaterialApp.router`'s builder.
  Future<GoRouter> pump(
    WidgetTester tester, {
    Size window = _phone,
    DeviceProfile profile = const DeviceProfile(),
  }) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) => shell,
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/home',
                  builder: (context, state) => _TapProbe(taps: taps),
                ),
              ],
            ),
          ],
        ),
        GoRoute(
          path: kPlayerRoutePath,
          builder: (context, state) => _TapProbe(taps: taps),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appRouterProvider.overrideWithValue(router),
          notificationServiceProvider.overrideWithValue(service),
          deviceProfileProvider.overrideWithValue(AsyncValue.data(profile)),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => M3ToastOverlay(child: child!),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  /// Fires one toast and settles its 420 ms entrance.
  Future<void> toast(WidgetTester tester) async {
    service.showToast(message: 'Download complete');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// Clears the queue in-body: a live toast holds a 3 s dismiss timer, and
  /// flutter_test checks for pending timers before tear-downs run.
  Future<void> drain(WidgetTester tester) async {
    for (final item in service.toasts) {
      service.dismissToast(item.id);
    }
    await tester.pump();
  }

  testWidgets('off the player, a toast eats the tap under it', (tester) async {
    await pump(tester);
    await toast(tester);

    expect(find.text('Download complete'), findsOneWidget);
    final card = tester.getRect(find.byType(InkWell));
    await tester.tapAt(card.center);
    await tester.pump();

    // The page is full-bleed and opaque, so the only thing that can have taken
    // this tap is the toast: `IgnorePointer(ignoring: false)` guards nothing.
    expect(taps, isEmpty);

    await drain(tester);
  });

  testWidgets('on the player, no toast is rendered and the tap gets through', (
    tester,
  ) async {
    final router = await pump(tester);

    // Calibrate against the real card rather than a hardcoded point.
    await toast(tester);
    final card = tester.getRect(find.byType(InkWell));
    await drain(tester);

    unawaited(router.push(kPlayerRoutePath));
    await tester.pumpAndSettle();
    await toast(tester);

    expect(find.text('Download complete'), findsNothing);
    expect(service.toasts, hasLength(1), reason: 'suppressed, not dropped');

    await tester.tapAt(card.center);
    await tester.pump();
    expect(taps, hasLength(1));

    await drain(tester);
  });

  testWidgets('the layer comes back when the player is popped', (tester) async {
    final router = await pump(tester);

    unawaited(router.push(kPlayerRoutePath));
    await tester.pumpAndSettle();
    await toast(tester);
    expect(find.text('Download complete'), findsNothing);

    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('Download complete'), findsOneWidget);

    await drain(tester);
  });

  group('a toast has to speak, because it cannot be found', () {
    /// Every status the app has - "Login failed", "No sources found",
    /// "Download complete" - arrives as one of these cards and takes itself
    /// away 3-4 s later. There is no window in which a screen-reader user
    /// could find it by exploration, so if the card does not announce itself
    /// the whole feedback channel is silent for them (WCAG 2.1 4.1.3).
    testWidgets('the card is a live region carrying the whole message', (
      tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await pump(tester);

      service.showError('Check your password', title: 'Login failed');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        tester.getSemantics(find.text('Check your password')),
        isSemantics(
          // Title and body in one node, joined the way the framework joins
          // merged labels, so the reader speaks the card and not a fragment.
          label: 'Login failed\nCheck your password',
          isLiveRegion: true,
        ),
      );

      await drain(tester);
      semantics.dispose();
    });

    testWidgets('a toast with no title announces its message', (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await pump(tester);
      await toast(tester);

      expect(
        tester.getSemantics(find.text('Download complete')),
        isSemantics(label: 'Download complete', isLiveRegion: true),
      );

      await drain(tester);
      semantics.dispose();
    });

    /// The card must be one region, not three. A live region per [Text] would
    /// speak the title, then the title and body again, on every toast - and
    /// the audit's other half is about not turning ordinary use into chatter.
    testWidgets('one region per card, whatever is in it', (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await pump(tester);

      service.showToast(title: 'Plugin updated', message: 'Nuvio 1.4.0');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final List<SemanticsNode> regions = <SemanticsNode>[];
      void visit(SemanticsNode node) {
        if (node.getSemanticsData().flagsCollection.isLiveRegion) {
          regions.add(node);
        }
        node.visitChildren((SemanticsNode child) {
          visit(child);
          return true;
        });
      }

      visit(tester.getSemantics(find.byType(M3ToastOverlay)));
      expect(regions, hasLength(1));

      await drain(tester);
      semantics.dispose();
    });
  });

  group('a hovered card that is taken away', () {
    /// Parks a mouse in the middle of the card, which pauses its dismiss
    /// timer. Flutter delivers no `onExit` when a hovered region is unmounted
    /// (widgets/basic.dart, [MouseRegion.onExit]), so whatever the card does
    /// on the way out is the only thing that can un-pause it.
    Future<TestGesture> hoverCard(WidgetTester tester) async {
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(
        location: tester.getRect(find.byType(InkWell)).center,
      );
      await tester.pump();
      return mouse;
    }

    testWidgets('still expires after the player takes the layer down', (
      tester,
    ) async {
      final router = await pump(tester);
      await toast(tester);
      final mouse = await hoverCard(tester);

      await tester.pump(const Duration(seconds: 10));
      expect(service.toasts, hasLength(1), reason: 'hover holds it open');

      // The layer stands down whole on the player route, so the card is
      // unmounted with the pointer still inside it.
      unawaited(router.push(kPlayerRoutePath));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 10));
      expect(
        service.toasts,
        isEmpty,
        reason: 'a paused timer nothing can resume is a permanent toast',
      );

      // Which is what the viewer would meet on the way back: a card that
      // never leaves, over a page whose clicks it eats.
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('Download complete'), findsNothing);

      await mouse.removePointer();
      await tester.pump();
    });

    testWidgets('does not strand a timer when it was dismissed first', (
      tester,
    ) async {
      await pump(tester);
      await toast(tester);
      final mouse = await hoverCard(tester);

      // Ending the hover from dispose runs for ordinary dismissal too, by
      // which point the toast is already out of the queue. Re-arming there
      // would leave a timer in the map for an id nothing will ever dismiss
      // again - which is what the binding's pending-timer check below fails
      // on.
      service.dismissToast(service.toasts.single.id);
      await tester.pump();
      expect(service.toasts, isEmpty);

      await mouse.removePointer();
      await tester.pump();
    });
  });

  group('the corner is a size decision', () {
    /// Just under the 720 dp threshold, in every device costume the old
    /// expression could have worn.
    const Size narrow = Size(700, 800);

    for (final (String name, DeviceProfile profile)
        in const <(String, DeviceProfile)>[
          ('a desktop window dragged narrow', DeviceProfile(isDesktopOS: true)),
          (
            'a television that somehow reported 700 dp',
            DeviceProfile(isTv: true),
          ),
          ('a phone', DeviceProfile()),
        ]) {
      testWidgets('$name gets a centred toast at 700 dp', (tester) async {
        await pump(tester, window: narrow, profile: profile);
        await toast(tester);

        final card = tester.getRect(find.byType(InkWell));
        expect(card.center.dx, 350, reason: 'centred in a 700 dp window');
        expect(card.right, lessThan(700 - 24), reason: 'not corner-anchored');

        await drain(tester);
      });
    }

    testWidgets('past 720 dp the toast takes the corner, whatever the device '
        'is', (tester) async {
      await pump(tester, window: const Size(800, 800));
      await toast(tester);

      // Align.bottomRight inside the layer's 24 dp padding.
      final card = tester.getRect(find.byType(InkWell));
      expect(card.right, 800 - 24);

      await drain(tester);
    });
  });

  test(
    'kPlayerRoutePath is the location PlayerRoute actually navigates to',
    () {
      expect(
        PlayerRoute(
          $extra: PlayerRouteExtra(
            item: MultimediaItem(title: 't', url: 'u', posterUrl: ''),
            videoUrl: 'u',
          ),
        ).location,
        kPlayerRoutePath,
      );
    },
  );
}
