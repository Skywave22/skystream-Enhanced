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
library;

import 'dart:async';

import 'package:flutter/material.dart';
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
  Future<GoRouter> pump(WidgetTester tester) async {
    tester.view.physicalSize = _phone;
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
          deviceProfileProvider.overrideWithValue(
            const AsyncValue.data(DeviceProfile()),
          ),
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
