import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/core/theme/theme_provider.dart';
import 'package:skystream/features/player/presentation/player_platform_service.dart';
import 'package:skystream/features/settings/presentation/app_version_provider.dart';
import 'package:skystream/features/settings/presentation/cache_provider.dart';
import 'package:skystream/features/settings/presentation/full_screen_mode_provider.dart';
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
    fullScreenModeActive.value = false;
  });

  ProviderContainer container() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  group('FullScreenMode', () {
    test('the provider and the player flag are one piece of state', () async {
      final c = container();
      expect(c.read(fullScreenModeProvider), isFalse);
      expect(fullScreenModeActive.value, isFalse);

      await c.read(fullScreenModeProvider.notifier).setEnabled(true);

      expect(c.read(fullScreenModeProvider), isTrue);
      expect(fullScreenModeActive.value, isTrue);
      expect(windowCalls, [true]);

      await c.read(fullScreenModeProvider.notifier).setEnabled(false);

      expect(c.read(fullScreenModeProvider), isFalse);
      expect(fullScreenModeActive.value, isFalse);
      expect(windowCalls, [true, false]);
    });

    test('a flag set before the provider is read is picked up', () async {
      fullScreenModeActive.value = true;
      expect(container().read(fullScreenModeProvider), isTrue);
    });

    test('asking for the state it is already in touches no window', () async {
      final c = container();
      await c.read(fullScreenModeProvider.notifier).setEnabled(false);
      expect(windowCalls, isEmpty);
    });

    test('every spelling of the launch argument boots into it', () async {
      for (final arg in kFullScreenModeLaunchArgs) {
        fullScreenModeActive.value = false;
        final c = container();
        c.read(fullScreenModeProvider.notifier).initialize(['skystream', arg]);
        expect(fullScreenModeActive.value, isTrue, reason: arg);
        expect(c.read(fullScreenModeProvider), isTrue, reason: arg);
      }
    });

    test('the retired --big-picture spellings are still honoured', () {
      // Both retired spellings stay as aliases so an existing shortcut or
      // launcher script keeps working. Named one by one rather than by
      // iterating the set, so dropping an alias fails here instead of quietly
      // shrinking what the loop above covers.
      expect(
        kFullScreenModeLaunchArgs,
        containsAll(<String>['--big-picture', '--bigpicture']),
        reason: 'an existing launcher must not break on the rename',
      );
      expect(
        kFullScreenModeLaunchArgs,
        containsAll(<String>['--full-screen', '--fullscreen']),
        reason: 'the new spelling has to work too, or the alias is the name',
      );

      for (final arg in <String>['--big-picture', '--full-screen']) {
        fullScreenModeActive.value = false;
        final c = container();
        c.read(fullScreenModeProvider.notifier).initialize(['skystream', arg]);
        expect(fullScreenModeActive.value, isTrue, reason: arg);
      }
    });

    test('an ordinary launch stays windowed', () async {
      final c = container();
      c.read(fullScreenModeProvider.notifier).initialize(['skystream']);
      expect(c.read(fullScreenModeProvider), isFalse);
      expect(windowCalls, isEmpty);
    });

    test('it hands the player the ten-foot form factor', () async {
      final c = container();
      const desktop = DeviceProfile(isDesktopOS: true);
      expect(playerFormFactorOf(desktop), PlayerFormFactor.desktop);

      await c.read(fullScreenModeProvider.notifier).setEnabled(true);

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
      expect(find.text('Full screen mode'), findsOneWidget);
    });

    testWidgets('is not offered where there is no window to full-screen', (
      tester,
    ) async {
      await pumpSettings(tester, platform: TargetPlatform.android);
      expect(find.text('Full screen mode'), findsNothing);
    });

    testWidgets('is not offered on a phone, so the row never has to hedge', (
      tester,
    ) async {
      // The subtitle promises a window to leave and a computer plugged into a
      // television, so the row must not reach either touch platform.
      for (final platform in <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        await pumpSettings(tester, platform: platform);
        expect(
          find.text('Full screen mode'),
          findsNothing,
          reason: '$platform has no window to full screen',
        );
      }
    });

    testWidgets('the switch drives the flag the player reads', (tester) async {
      await pumpSettings(tester, platform: TargetPlatform.macOS);
      // Named through its own row rather than by index: the General group
      // carries another switch, and "the last one" is not a promise.
      final toggle = find.descendant(
        of: find.ancestor(
          of: find.text('Full screen mode'),
          matching: find.byType(SettingsTile),
        ),
        matching: find.byType(Switch),
      );

      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(fullScreenModeActive.value, isTrue);
      expect(windowCalls, [true]);
      expect(tester.widget<Switch>(toggle).value, isTrue);
    });

    testWidgets('the row names both states and what full screen costs', (
      tester,
    ) async {
      // The wording names full screen, names windowed as the other state and
      // says the ten-foot layout comes with it. Asserted as three properties
      // rather than one string equality, so the copy can be improved without
      // this test becoming a spelling checker.
      await pumpSettings(tester, platform: TargetPlatform.macOS);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final String row = '${l10n.fullScreenMode} ${l10n.fullScreenModeSubtitle}'
          .toLowerCase();

      expect(row, contains('full screen'));
      expect(
        row,
        contains('windowed'),
        reason: 'the off state is a named mode, not just "not full screen"',
      );
      expect(
        row,
        anyOf(contains('ten-foot'), contains('tv layout')),
        reason:
            'full screen also switches the player to the ten-foot layout; a '
            'viewer who is only told about the window is being misled',
      );
      expect(find.text(l10n.fullScreenModeSubtitle), findsOneWidget);
    });

    test('hi and kn say it in their own words, not in English', () async {
      // The l10n ratchet only checks that a key is present, so check these
      // two were translated rather than pasted.
      final en = await AppLocalizations.delegate.load(const Locale('en'));
      for (final code in <String>['hi', 'kn']) {
        final l10n = await AppLocalizations.delegate.load(Locale(code));
        expect(l10n.fullScreenMode, isNotEmpty, reason: code);
        expect(l10n.fullScreenMode, isNot(en.fullScreenMode), reason: code);
        expect(
          l10n.fullScreenModeSubtitle,
          isNot(en.fullScreenModeSubtitle),
          reason: code,
        );
      }
    });
  });

  test('the Steam name survives only where it has to', () {
    // "Big Picture" is Steam's branding and is retired. A source guard rather
    // than a naming convention, because the name is the sort of thing that
    // comes back in a doc comment nobody re-reads.
    //
    // The one thing that may still say it is the launch-argument alias in
    // full_screen_mode_provider.dart, which exists so an existing shortcut
    // keeps working, and the doc comment that explains why.
    final Set<String> allowed = <String>{
      'lib/features/settings/presentation/full_screen_mode_provider.dart',
    };
    final RegExp steam = RegExp(r'big[\s_-]?picture', caseSensitive: false);
    final Directory lib = Directory('lib');
    expect(
      lib.existsSync(),
      isTrue,
      reason: 'run this from the package root so lib/ resolves',
    );

    final List<String> hits = <String>[];
    for (final FileSystemEntity entity in lib.listSync(recursive: true)) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.dart') && !entity.path.endsWith('.arb')) {
        continue;
      }
      final String relative = entity.path.replaceAll(
        Platform.pathSeparator,
        '/',
      );
      if (allowed.contains(relative)) continue;
      final List<String> lines = entity.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        if (steam.hasMatch(lines[i])) {
          hits.add('$relative:${i + 1}: ${lines[i].trim()}');
        }
      }
    }

    expect(
      hits,
      isEmpty,
      reason:
          'Steam\'s "Big Picture" branding is retired. The setting, the '
          'provider, the flag and the ARB keys are all "full screen mode" '
          'now.\n${hits.join('\n')}',
    );
  });
}
