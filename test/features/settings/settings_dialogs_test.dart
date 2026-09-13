import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/network/doh_service.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/features/player/presentation/player_platform_service.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/features/settings/presentation/widgets/settings_dialogs.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// Keeps [playerSettingsProvider] off the on-disk repository: these tests are
/// about what the dialogs *offer*, not about what is stored.
class _StubPlayerSettings extends PlayerSettingsNotifier {
  @override
  Future<PlayerSettings> build() async => const PlayerSettings();
}

/// Keeps the DoH picker off SharedPreferences.
class _StubDoh extends DohSettingsNotifier {
  _StubDoh(this._value);

  final DohSettings _value;

  @override
  Future<DohSettings> build() async => _value;
}

/// Pumps a single button that opens [open] with a real [WidgetRef].
Future<void> _pumpOpener(
  WidgetTester tester, {
  required void Function(BuildContext, WidgetRef) open,
  TargetPlatform platform = TargetPlatform.android,
  DeviceProfile profile = const DeviceProfile(),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        deviceProfileProvider.overrideWithValue(AsyncValue.data(profile)),
        playerSettingsProvider.overrideWith(_StubPlayerSettings.new),
      ],
      child: MaterialApp(
        theme: ThemeData(platform: platform),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => open(context, ref),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// The title of the [ListTile] that currently owns the primary focus, or null
/// if focus is not inside a row.
String? _focusedRowTitle() {
  final BuildContext? context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return null;
  final ListTile? tile = context.findAncestorWidgetOfExactType<ListTile>();
  final Widget? title = tile?.title;
  return title is Text ? title.data : null;
}

void main() {
  // playerFormFactorOf() reads this global, and the Big Picture test in this
  // directory flips it. Leave it as we found it.
  setUp(() => fullScreenModeActive.value = false);
  tearDown(() => fullScreenModeActive.value = false);

  group(
    'showPlayerControlsDialog only offers buttons this device can draw',
    () {
      // Every row's label, in the order the dialog builds them.
      const String pip = 'Picture-in-Picture button';
      const String resize = 'Resize button';
      const String speed = 'Playback speed button';
      const String episodes = 'Episodes button';

      /// The label the retired rotate switch carried. No device may offer it:
      /// the player draws no rotate button for it to hide.
      const String rotate = 'Rotate button';

      /// (case name, platform, profile, rows that must be offered).
      final cases = <(String, TargetPlatform, DeviceProfile, List<String>)>[
        (
          'Android phone — the only device that gets the PiP row',
          TargetPlatform.android,
          const DeviceProfile(),
          [pip, resize, speed, episodes],
        ),
        (
          'Android tablet',
          TargetPlatform.android,
          const DeviceProfile(isTablet: true),
          [pip, resize, speed, episodes],
        ),
        (
          'Android TV — nothing to shrink into',
          TargetPlatform.android,
          const DeviceProfile(isTv: true),
          [resize, speed, episodes],
        ),
        (
          'iPhone — no OS-level PiP for us',
          TargetPlatform.iOS,
          const DeviceProfile(),
          [resize, speed, episodes],
        ),
        (
          'iPad',
          TargetPlatform.iOS,
          const DeviceProfile(isTablet: true),
          [resize, speed, episodes],
        ),
        (
          'macOS',
          TargetPlatform.macOS,
          const DeviceProfile(isDesktopOS: true),
          [resize, speed, episodes],
        ),
        (
          'Windows',
          TargetPlatform.windows,
          const DeviceProfile(isDesktopOS: true),
          [resize, speed, episodes],
        ),
        (
          'Linux',
          TargetPlatform.linux,
          const DeviceProfile(isDesktopOS: true),
          [resize, speed, episodes],
        ),
      ];

      for (final (name, platform, profile, expected) in cases) {
        testWidgets(name, (tester) async {
          await _pumpOpener(
            tester,
            open: showPlayerControlsDialog,
            platform: platform,
            profile: profile,
          );

          expect(find.text('Player Controls'), findsOneWidget);
          for (final String label in <String>[
            pip,
            resize,
            rotate,
            speed,
            episodes,
          ]) {
            expect(
              find.text(label),
              expected.contains(label) ? findsOneWidget : findsNothing,
              reason: '$label on $name',
            );
          }
          expect(find.byType(SwitchListTile), findsNWidgets(expected.length));
        });
      }

      testWidgets('Big Picture on a desktop is treated as the television it '
          'imitates', (tester) async {
        fullScreenModeActive.value = true;
        await _pumpOpener(
          tester,
          open: showPlayerControlsDialog,
          platform: TargetPlatform.android,
          profile: const DeviceProfile(),
        );
        expect(find.text(pip), findsNothing);
        expect(find.text(rotate), findsNothing);
      });

      test('the predicates are the player screen\'s own, spelled out', () {
        // PiP: Android, anywhere but a television.
        expect(
          playerCanShowPip(TargetPlatform.android, PlayerFormFactor.phone),
          isTrue,
        );
        expect(
          playerCanShowPip(TargetPlatform.android, PlayerFormFactor.tablet),
          isTrue,
        );
        expect(
          playerCanShowPip(TargetPlatform.android, PlayerFormFactor.tv),
          isFalse,
        );
        expect(
          playerCanShowPip(TargetPlatform.iOS, PlayerFormFactor.phone),
          isFalse,
        );
        expect(
          playerCanShowPip(TargetPlatform.macOS, PlayerFormFactor.desktop),
          isFalse,
        );

        // An unresolved device profile is "we do not know". PiP survives it
        // because the player's own `_pipAvailable` does: the callback is
        // non-null on Android until the profile says television.
        expect(
          playerCanShowPip(TargetPlatform.android, PlayerFormFactor.unknown),
          isTrue,
        );
      });

      testWidgets('the rotate row is gone on the two devices that used to '
          'get it', (tester) async {
        // An Android phone and an Android tablet were the shapes where the
        // retired predicate was true, so they are the shapes where a
        // resurrected row would show up first. The player builds no rotate
        // button on either any more (see
        // test/features/player/orientation_follows_video_test.dart), so a
        // switch here would move a stored boolean and change nothing.
        for (final DeviceProfile profile in <DeviceProfile>[
          const DeviceProfile(),
          const DeviceProfile(isTablet: true),
        ]) {
          await _pumpOpener(
            tester,
            open: showPlayerControlsDialog,
            platform: TargetPlatform.android,
            profile: profile,
          );
          expect(find.text(rotate), findsNothing);
          expect(find.byIcon(Icons.screen_rotation_rounded), findsNothing);
          expect(find.byType(SwitchListTile), findsNWidgets(4));
          await tester.tap(find.text('Close'));
          await tester.pumpAndSettle();
        }
      });
    },
  );

  group('a picker opens on the value that is already set', () {
    testWidgets('seek duration focuses the current row, not the first', (
      tester,
    ) async {
      await _pumpOpener(
        tester,
        open: (context, ref) => showDurationDialog(context, ref, 30),
      );

      expect(find.text('5 sec'), findsOneWidget, reason: 'row one is present');
      expect(_focusedRowTitle(), '30 sec');
    });

    testWidgets('resize focuses the current row', (tester) async {
      await _pumpOpener(
        tester,
        open: (context, ref) => showResizeDialog(context, ref, 'Stretch'),
      );
      expect(_focusedRowTitle(), 'Stretch');
    });

    testWidgets('theme focuses the current row', (tester) async {
      await _pumpOpener(
        tester,
        open: (context, ref) => showThemeDialog(context, ref, ThemeMode.light),
      );
      expect(_focusedRowTitle(), 'Light');
    });

    testWidgets('gesture focuses the current row', (tester) async {
      await _pumpOpener(
        tester,
        open: (context, ref) =>
            showGestureDialog(context, ref, true, PlayerGesture.none),
      );
      expect(_focusedRowTitle(), 'None');
    });

    testWidgets('a value with no matching row claims nothing, rather than '
        'letting two rows claim it', (tester) async {
      // 45 s is not one of the offered durations.
      await _pumpOpener(
        tester,
        open: (context, ref) => showDurationDialog(context, ref, 45),
      );
      expect(tester.takeException(), isNull);
      expect(_focusedRowTitle(), isNull);
    });

    testWidgets('a long picker scrolls the current row into view, not just '
        'focuses it off screen', (tester) async {
      // 20 rows of 56 dp cannot fit an 800x600 dialog; 20 min is the last.
      await _pumpOpener(
        tester,
        open: (context, ref) => showReadaheadDialog(context, ref, 20 * 60),
      );

      expect(_focusedRowTitle(), '20 min');

      final Finder viewport = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(Scrollable),
      );
      final Rect viewportRect = tester.getRect(viewport);
      final Rect rowRect = tester.getRect(
        find.ancestor(of: find.text('20 min'), matching: find.byType(ListTile)),
      );
      final Rect firstRowRect = tester.getRect(
        find.ancestor(of: find.text('1 min'), matching: find.byType(ListTile)),
      );

      // The list is genuinely taller than its viewport, or this proves nothing.
      expect(
        rowRect.bottom - firstRowRect.top,
        greaterThan(viewportRect.height),
        reason: 'picker must overflow for the scroll to matter',
      );
      expect(
        viewportRect.contains(rowRect.topLeft) &&
            viewportRect.contains(rowRect.bottomRight - const Offset(1, 1)),
        isTrue,
        reason: 'row $rowRect is not inside viewport $viewportRect',
      );
    });

    testWidgets('the DoH picker on Custom leaves the URL field the only '
        'claimant, so no scope has two', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dohSettingsProvider.overrideWith(
              () => _StubDoh(
                const DohSettings(
                  provider: DohProvider.custom,
                  customUrl: 'https://example.test/dns-query',
                ),
              ),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  // Watched so the stub has resolved before the dialog's
                  // initState reads it.
                  ref.watch(dohSettingsProvider);
                  return TextButton(
                    onPressed: () => showDohProviderDialog(context, ref),
                    child: const Text('open'),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(_focusedRowTitle(), isNull, reason: 'no row may claim focus here');
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<EditableText>()
            ?.controller
            .text,
        'https://example.test/dns-query',
      );
    });

    testWidgets('the DoH picker on a plain provider focuses that row', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dohSettingsProvider.overrideWith(
              () => _StubDoh(const DohSettings(provider: DohProvider.quad9)),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  ref.watch(dohSettingsProvider);
                  return TextButton(
                    onPressed: () => showDohProviderDialog(context, ref),
                    child: const Text('open'),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(_focusedRowTitle(), 'Quad9');
    });
  });
}
