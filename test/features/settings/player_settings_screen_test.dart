import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/features/settings/presentation/player_settings_screen.dart';
import 'package:skystream/features/settings/presentation/widgets/settings_widgets.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// The four gesture rows - Left gesture, Right gesture, Double-tap to seek,
/// Swipe to seek - are the only place in the app where the player's touch
/// gestures are discoverable and switchable.
///
/// They used to be gated on `profile.isTv || context.isTv`, and the second
/// term was a guess: `Platform.isAndroid && aspectRatio > 1.0 &&
/// padding.top == 0`. An Android phone in landscape - or one on its way out of
/// the player, which runs `immersiveSticky` and restores the insets in
/// `dispose` - answered yes and lost all four rows while the gestures kept
/// firing under its thumb. The viewer could no longer switch off a gesture
/// that was still happening.
///
/// A touchscreen is a hardware fact and the one input the consistency policy
/// lets the UI branch on. So the gate is now hardware: a mobile OS that is not
/// a leanback box or an Apple TV. Window shape does not reach it.
void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  List<String> gestureRowTitles() => <String>[
    l10n.leftGesture,
    l10n.rightGesture,
    l10n.doubleTapToSeek,
    l10n.swipeToSeek,
  ];

  Future<void> pumpPlayerSettings(
    WidgetTester tester, {
    required TargetPlatform platform,
    required DeviceProfile profile,
    Size size = const Size(390, 844),
    NavigationMode navigationMode = NavigationMode.traditional,
    PlayerSettings settings = const PlayerSettings(),
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    tester.view.padding = FakeViewPadding.zero;
    tester.view.viewInsets = FakeViewPadding.zero;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceProfileProvider.overrideWithValue(AsyncValue.data(profile)),
          playerSettingsProvider.overrideWithBuild((_, _) => settings),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(platform: platform),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(navigationMode: navigationMode),
            child: child!,
          ),
          home: const PlayerSettingsScreen(isEmbedded: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an Android phone in landscape with no top inset keeps all four '
      'gesture rows, and they are laid out on screen', (
    WidgetTester tester,
  ) async {
    await pumpPlayerSettings(
      tester,
      platform: TargetPlatform.android,
      profile: const DeviceProfile(),
      size: const Size(844, 390),
    );

    final Size surface = tester.view.physicalSize;
    for (final String title in gestureRowTitles()) {
      final Finder row = find.text(title);
      expect(row, findsOneWidget, reason: title);
      final Rect rect = tester.getRect(row);
      expect(rect.height, greaterThan(0), reason: title);
      expect(rect.width, greaterThan(0), reason: title);
      expect(rect.top, lessThan(surface.height), reason: '$title off-screen');
      expect(rect.left, greaterThanOrEqualTo(0), reason: title);
    }
  });

  testWidgets('a phone driven by a D-pad still has a touchscreen, so it keeps '
      'the gesture rows', (WidgetTester tester) async {
    // The old gate read the input model - directional focus movement - as a
    // device class. A paired controller does not remove the glass.
    await pumpPlayerSettings(
      tester,
      platform: TargetPlatform.android,
      profile: const DeviceProfile(),
      size: const Size(844, 390),
      navigationMode: NavigationMode.directional,
    );

    for (final String title in gestureRowTitles()) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
  });

  testWidgets('an iPhone in portrait keeps the gesture rows', (
    WidgetTester tester,
  ) async {
    await pumpPlayerSettings(
      tester,
      platform: TargetPlatform.iOS,
      profile: const DeviceProfile(),
    );

    for (final String title in gestureRowTitles()) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
  });

  testWidgets('a television has no touchscreen, so the rows stay hidden', (
    WidgetTester tester,
  ) async {
    // Android TV at 1080p: 960x540 dp. Leanback is the authority, and it is
    // the only thing that hides these rows on a mobile OS.
    await pumpPlayerSettings(
      tester,
      platform: TargetPlatform.android,
      profile: const DeviceProfile(isTv: true, isTablet: true),
      size: const Size(960, 540),
      navigationMode: NavigationMode.directional,
    );

    for (final String title in gestureRowTitles()) {
      expect(find.text(title), findsNothing, reason: title);
    }
    // The rest of the screen is untouched by the gate.
    expect(find.text(l10n.defaultPlayer), findsOneWidget);
  });

  testWidgets('a desktop window narrow enough to look like a phone still has '
      'no gesture rows', (WidgetTester tester) async {
    await pumpPlayerSettings(
      tester,
      platform: TargetPlatform.macOS,
      profile: const DeviceProfile(isDesktopOS: true),
      size: const Size(420, 900),
    );

    for (final String title in gestureRowTitles()) {
      expect(find.text(title), findsNothing, reason: title);
    }
    expect(find.text(l10n.defaultPlayer), findsOneWidget);
  });

  /// The subtitles-by-default row.
  ///
  /// Not gated on anything - a television has subtitles too - so the only
  /// questions are that it is there and that it reads back the value in force
  /// rather than a fixed word. Read off the [SettingsTile] rather than by
  /// finding the text: "Auto" is also what the default-player row says, and a
  /// bare text finder cannot tell the two rows apart.
  String subtitleDefaultRow(WidgetTester tester) => tester
      .widgetList<SettingsTile>(find.byType(SettingsTile, skipOffstage: false))
      .firstWhere((SettingsTile tile) => tile.title == l10n.subtitleDefault)
      .subtitle!;

  testWidgets('the subtitle default row reads Auto on a fresh install', (
    WidgetTester tester,
  ) async {
    await pumpPlayerSettings(
      tester,
      platform: TargetPlatform.android,
      profile: const DeviceProfile(),
    );

    expect(subtitleDefaultRow(tester), l10n.subtitleDefaultAuto);
  });

  testWidgets('the subtitle default row reads back a stored Off', (
    WidgetTester tester,
  ) async {
    // A separate test rather than a second pump in the one above: the scope is
    // rebuilt, not rebuilt from scratch, and a keepAlive notifier that has
    // already answered does not re-run its build for a new override.
    await pumpPlayerSettings(
      tester,
      platform: TargetPlatform.android,
      profile: const DeviceProfile(),
      settings: const PlayerSettings(subtitleDefault: SubtitleDefault.off),
    );

    expect(
      subtitleDefaultRow(tester),
      l10n.off,
      reason: 'the row is a read-out, not a label',
    );
  });

  testWidgets('a television keeps the subtitle default row', (
    WidgetTester tester,
  ) async {
    await pumpPlayerSettings(
      tester,
      platform: TargetPlatform.android,
      profile: const DeviceProfile(isTv: true),
      size: const Size(1920, 1080),
    );

    expect(find.text(l10n.subtitleDefault), findsOneWidget);
  });

  /// Hardware decoding is the one row whose switch cannot reach a decoder
  /// everywhere, so it is offered only where it decides something.
  ///
  /// The preference is emitted as an instance-level `--avcodec-hw`. On Windows
  /// and Linux `libvlc_video_set_callbacks` sets `avcodec-hw = "none"` on the
  /// media player as it installs the vmem callbacks, and `var_Inherit` stops
  /// at the first object holding the variable — the media player sits below
  /// the instance, so the option never arrives and both decode in software
  /// whichever way the switch is set. On iOS and macOS the decoder is
  /// VideoToolbox, a standalone module in VLC 3 rather than an avcodec
  /// accelerator, so `avcodec-hw` has no authority over it and the hardware
  /// path is there either way.
  ///
  /// A row that reports "Enabled" over software decode, or "Disabled" over a
  /// hardware one, is worse than no row: it is the app stating something
  /// untrue about itself. See [hardwareDecodeAvailable], which is what the
  /// player actually consults.
  group('the hardware decoding row', () {
    testWidgets('is offered on Android, where the switch decides', (
      WidgetTester tester,
    ) async {
      await pumpPlayerSettings(
        tester,
        platform: TargetPlatform.android,
        profile: const DeviceProfile(),
      );

      expect(find.text(l10n.hardwareDecoding), findsOneWidget);
    });

    testWidgets('is offered on an Android television too', (
      WidgetTester tester,
    ) async {
      // The gate is the decoder, not the form factor: a leanback box runs the
      // same avcodec path a phone does.
      await pumpPlayerSettings(
        tester,
        platform: TargetPlatform.android,
        profile: const DeviceProfile(isTv: true),
        size: const Size(1920, 1080),
      );

      expect(find.text(l10n.hardwareDecoding), findsOneWidget);
    });

    for (final platform in <TargetPlatform>[
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      testWidgets('is not offered on $platform, where it decides nothing', (
        WidgetTester tester,
      ) async {
        await pumpPlayerSettings(
          tester,
          platform: platform,
          profile: DeviceProfile(
            isDesktopOS:
                platform != TargetPlatform.iOS &&
                platform != TargetPlatform.android,
          ),
          size: const Size(1280, 800),
        );

        expect(
          find.text(l10n.hardwareDecoding),
          findsNothing,
          reason:
              '$platform ignores the preference, so the row would be a switch '
              'that reports a decoder the app is not using',
        );
      });
    }
  });
}
