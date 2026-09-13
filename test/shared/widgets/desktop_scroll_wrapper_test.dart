/// Who gets the rail's scroll arrows, and who decides.
///
/// The arrows are a pointer affordance: on a television there is nothing to
/// click them with and the D-pad walks the rail directly, so they are hidden
/// there. That verdict used to be asked twice - once of `DeviceProfile.isTv`
/// (leanback, or an Apple TV `utsname`) and once, "as a fallback while the
/// provider loads", of `context.isTv`. The second reading forwarded to
/// [MediaQueryData.navigationMode], which no host in this app ever sets, so it
/// was false on the televisions it was meant to catch and could only ever fire
/// somewhere else. It is gone; the profile is the only authority left.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/shared/widgets/desktop_scroll_wrapper.dart';

/// `showButtons: true` is passed at every call below so the verdict under
/// test is the TV check and not the host the suite happens to run on - the
/// default arm of `_shouldShowButtons` is `Platform.isMacOS || ...`.
Future<void> _pumpRail(
  WidgetTester tester, {
  required DeviceProfile profile,
  NavigationMode navigationMode = NavigationMode.traditional,
}) async {
  final ScrollController controller = ScrollController();
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        deviceProfileProvider.overrideWithValue(
          AsyncValue<DeviceProfile>.data(profile),
        ),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(navigationMode: navigationMode),
            child: Center(
              // A real rail is width-constrained and its content overflows,
              // which is the only state in which either arrow is offered.
              child: SizedBox(
                width: 400,
                height: 120,
                child: DesktopScrollWrapper(
                  controller: controller,
                  showButtons: true,
                  child: ListView.builder(
                    controller: controller,
                    scrollDirection: Axis.horizontal,
                    itemCount: 20,
                    itemBuilder: (_, int i) =>
                        SizedBox(width: 100, child: Text('card $i')),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  // The arrows are decided in a post-frame callback off the scroll metrics.
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('a leanback television gets no arrows, even when the caller '
      'asked for them', (WidgetTester tester) async {
    await _pumpRail(tester, profile: const DeviceProfile(isTv: true));

    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.byIcon(Icons.chevron_left), findsNothing);
  });

  testWidgets('a directional navigation mode is not a television', (
    WidgetTester tester,
  ) async {
    // Everything a TV would report except the one fact that makes it a TV.
    // The old fallback read exactly this and hid the arrows on whatever
    // surface declared it - a desktop with a keyboard, a phone with a pad.
    await _pumpRail(
      tester,
      profile: const DeviceProfile(isDesktopOS: true),
      navigationMode: NavigationMode.directional,
    );

    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
  });

  testWidgets('an ordinary desktop rail keeps its arrows', (
    WidgetTester tester,
  ) async {
    await _pumpRail(tester, profile: const DeviceProfile(isDesktopOS: true));

    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    // Nothing has scrolled yet, so there is nothing to the left.
    expect(find.byIcon(Icons.chevron_left), findsNothing);
  });
}
