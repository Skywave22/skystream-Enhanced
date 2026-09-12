import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/core/theme/theme_provider.dart';
import 'package:skystream/features/player/presentation/player_platform_service.dart';
import 'package:skystream/features/settings/presentation/app_version_provider.dart';
import 'package:skystream/features/settings/presentation/big_picture_provider.dart';
import 'package:skystream/features/settings/presentation/cache_provider.dart';
import 'package:skystream/features/settings/presentation/general_settings_provider.dart';
import 'package:skystream/features/settings/presentation/settings_screen.dart';
import 'package:skystream/features/settings/presentation/widgets/settings_widgets.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

const MethodChannel _windowChannel = MethodChannel('window_manager');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Every `setFullScreen` the window plugin was asked for, in order.
  late List<bool> windowCalls;

  setUp(() {
    windowCalls = [];
    messenger.setMockMethodCallHandler(_windowChannel, (call) async {
      if (call.method == 'setFullScreen') {
        final args = call.arguments as Map<Object?, Object?>;
        windowCalls.add(args['isFullScreen'] as bool);
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_windowChannel, null);
    // Process-wide, so it has to be handed back or the next test inherits a
    // television.
    bigPictureActive.value = false;
  });

  ProviderContainer container() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  group('BigPictureMode', () {
    test('the provider and the player flag are one piece of state', () async {
      final c = container();
      expect(c.read(bigPictureModeProvider), isFalse);
      expect(bigPictureActive.value, isFalse);

      await c.read(bigPictureModeProvider.notifier).setEnabled(true);

      expect(c.read(bigPictureModeProvider), isTrue);
      expect(bigPictureActive.value, isTrue);
      expect(windowCalls, [true]);

      await c.read(bigPictureModeProvider.notifier).setEnabled(false);

      expect(c.read(bigPictureModeProvider), isFalse);
      expect(bigPictureActive.value, isFalse);
      expect(windowCalls, [true, false]);
    });

    test('a flag set before the provider is read is picked up', () async {
      bigPictureActive.value = true;
      expect(container().read(bigPictureModeProvider), isTrue);
    });

    test('asking for the state it is already in touches no window', () async {
      final c = container();
      await c.read(bigPictureModeProvider.notifier).setEnabled(false);
      expect(windowCalls, isEmpty);
    });

    test('either spelling of the launch argument boots into it', () async {
      for (final arg in kBigPictureLaunchArgs) {
        bigPictureActive.value = false;
        final c = container();
        c.read(bigPictureModeProvider.notifier).initialize(['skystream', arg]);
        expect(bigPictureActive.value, isTrue, reason: arg);
        expect(c.read(bigPictureModeProvider), isTrue, reason: arg);
      }
    });

    test('an ordinary launch stays windowed', () async {
      final c = container();
      c.read(bigPictureModeProvider.notifier).initialize(['skystream']);
      expect(c.read(bigPictureModeProvider), isFalse);
      expect(windowCalls, isEmpty);
    });

    test('it hands the player the ten-foot form factor', () async {
      final c = container();
      const desktop = DeviceProfile(isDesktopOS: true);
      expect(playerFormFactorOf(desktop), PlayerFormFactor.desktop);

      await c.read(bigPictureModeProvider.notifier).setEnabled(true);

      expect(
        playerFormFactorOf(desktop),
        PlayerFormFactor.tv,
        reason:
            'this is the whole feature: the player already branches on the '
            'form factor everywhere, so nothing else has to change',
      );
    });
  });

  group('the settings toggle', () {
    Future<void> pumpSettings(
      WidgetTester tester, {
      required TargetPlatform platform,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appThemeModeProvider.overrideWithValue(ThemeMode.dark),
            generalSettingsProvider.overrideWithValue(const GeneralSettings()),
            appVersionProvider.overrideWith((ref) async => '1.0.0 +1'),
            cacheSizeProvider.overrideWith((ref) async => 0),
          ],
          child: MaterialApp(
            theme: ThemeData(platform: platform),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const SettingsScreen(),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('is offered on a desktop', (tester) async {
      await pumpSettings(tester, platform: TargetPlatform.macOS);
      expect(find.text('Big Picture Mode'), findsOneWidget);
    });

    testWidgets('is not offered where there is no window to full-screen', (
      tester,
    ) async {
      await pumpSettings(tester, platform: TargetPlatform.android);
      expect(find.text('Big Picture Mode'), findsNothing);
    });

    testWidgets('the switch drives the flag the player reads', (tester) async {
      await pumpSettings(tester, platform: TargetPlatform.macOS);
      // Named through its own row rather than by index: the General group
      // carries another switch, and "the last one" is not a promise.
      final toggle = find.descendant(
        of: find.ancestor(
          of: find.text('Big Picture Mode'),
          matching: find.byType(SettingsTile),
        ),
        matching: find.byType(Switch),
      );

      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(bigPictureActive.value, isTrue);
      expect(windowCalls, [true]);
      expect(tester.widget<Switch>(toggle).value, isTrue);
    });
  });
}
