import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';

/// Source of [PlayerSettings], read as text.
///
/// The guard below is about a parameter that *exists in the signature*, which
/// no amount of calling the API can observe: a `copyWith` argument with no
/// backing field compiles, runs, and silently does nothing. Only the source
/// text can tell us it is there.
const String _source =
    'lib/features/settings/presentation/player_settings_provider.dart';

/// `copyWith` parameters that intentionally have no field of the same name.
///
/// A nullable field cannot be *cleared* through `T? x` — passing null is
/// indistinguishable from passing nothing — so [PlayerSettings.preferredPlayer]
/// takes a companion flag instead. That is a deliberate pattern, not debris.
const Set<String> _fieldlessByDesign = <String>{'clearPreferredPlayer'};

String _classBody(String src) {
  final int start = src.indexOf('class PlayerSettings {');
  final int end = src.indexOf('  const PlayerSettings({', start);
  expect(start, isNonNegative, reason: 'class PlayerSettings not found');
  expect(end, greaterThan(start), reason: 'PlayerSettings constructor moved');
  return src.substring(start, end);
}

String _copyWithParams(String src) {
  final int start = src.indexOf('PlayerSettings copyWith({');
  expect(start, isNonNegative, reason: 'PlayerSettings.copyWith not found');
  final int end = src.indexOf('\n  }) {', start);
  expect(end, greaterThan(start), reason: 'copyWith signature not closed');
  return src.substring(start, end);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test('every copyWith parameter is backed by a field', () {
    final String src = File(_source).readAsStringSync();

    final Set<String> fields = RegExp(
      r'\bfinal\s+[^;]*?(\w+)\s*;',
    ).allMatches(_classBody(src)).map((RegExpMatch m) => m.group(1)!).toSet();
    expect(
      fields,
      contains('subtitleSize'),
      reason: 'field scrape is broken, not the class',
    );

    final List<String> params = <String>[];
    for (final String line in _copyWithParams(src).split('\n').skip(1)) {
      final RegExpMatch? m = RegExp(
        r'(\w+)\s*(?:=\s*[^,]+)?,\s*$',
      ).firstMatch(line);
      if (m != null) params.add(m.group(1)!);
    }
    expect(
      params.length,
      greaterThan(20),
      reason: 'parameter scrape is broken, not the signature',
    );

    final List<String> dead = params
        .where((String p) => !fields.contains(p))
        .where((String p) => !_fieldlessByDesign.contains(p))
        .toList();

    expect(
      dead,
      isEmpty,
      reason:
          'copyWith takes ${dead.join(', ')} but PlayerSettings has no such '
          'field, so passing one is silently ignored. Six of these were left '
          'behind when the media_kit subtitle model was deleted.',
    );
  });

  test('the Wi-Fi quality ceiling defaults to 1080p, not 4K', () {
    // Deliberate: a 3840x2160 render target is ~33 MB per frame and there is
    // no in-app escape once a 4K stream is picked. Reverting this to q4k was
    // proposed and rejected; the constant and both of its use sites stay.
    expect(kDefaultWifiQuality, QualityPreference.q1080);
    expect(const PlayerSettings().wifiQuality, kDefaultWifiQuality);
    expect(const PlayerSettings().mobileQuality, QualityPreference.q1080);

    final String src = File(_source).readAsStringSync();
    expect(
      RegExp(r'\bkDefaultWifiQuality\b').allMatches(src).length,
      greaterThanOrEqualTo(3),
      reason: 'the constant, the field default and the storage fallback',
    );
    expect(
      src.contains('QualityPreference.q4k,\n'),
      isFalse,
      reason: 'no default may be hardcoded to 4K',
    );
  });

  test('the live subtitle appearance fields survive copyWith', () {
    const PlayerSettings defaults = PlayerSettings();
    expect(defaults.subtitleSize, 22.0);
    expect(defaults.subtitleColor, 0xFFFFFFFF);
    expect(defaults.subtitleBackgroundColor, 0x00000000);
    expect(defaults.subtitleBackgroundOpacity, 0.5);

    final PlayerSettings styled = defaults.copyWith(
      subtitleSize: 30.0,
      subtitleColor: 0xFFFFEB3B,
      subtitleBackgroundColor: 0xFF303030,
      subtitleBackgroundOpacity: 0.0,
    );
    expect(styled.subtitleSize, 30.0);
    expect(styled.subtitleColor, 0xFFFFEB3B);
    expect(styled.subtitleBackgroundColor, 0xFF303030);
    expect(styled.subtitleBackgroundOpacity, 0.0);
    expect(styled.wifiQuality, kDefaultWifiQuality);
  });

  /// The OpenSubtitles and SubDL passwords are *account* passwords the user
  /// reuses elsewhere, not revocable API tokens. Held in the Hive settings box
  /// they were copied verbatim into Android's cloud backup and into iOS
  /// device-to-device transfer and unencrypted Finder backups.
  ///
  /// Driven against a real [StorageService] on a real Hive box in a temp
  /// directory and the real notifier, so "the box no longer holds it" is the
  /// genuine on-disk state and not a fake's opinion. The secure backend is the
  /// package's own in-memory test platform, whose map is the same instance
  /// handed to [FlutterSecureStorage.setMockInitialValues] — so the assertions
  /// below read what the Keychain/Keystore would have been given.
  group('subtitle account passwords live in the platform secure store', () {
    late Directory dir;
    late StorageService storage;
    late Map<String, String> keychain;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('player_settings_creds');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall call) async => dir.path,
      );
      storage = StorageService();
      await storage.init();
      keychain = <String, String>{};
      FlutterSecureStorage.setMockInitialValues(keychain);
    });

    tearDown(() async {
      await Hive.close();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    ProviderContainer boot() {
      final ProviderContainer container = ProviderContainer(
        overrides: [storageServiceProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      return container;
    }

    test(
      'a password left behind by an older build migrates out of Hive',
      () async {
        // Exactly what an upgrading user has on disk: the plaintext keys the
        // previous build wrote, in the box that gets backed up.
        await storage.setPlayerSetting('player_os_user', 'ada');
        await storage.setPlayerSetting('player_os_pass', 'hunter2');
        await storage.setPlayerSetting(
          'player_subdl_email',
          'ada@example.test',
        );
        await storage.setPlayerSetting('player_subdl_pass', 'correct-horse');

        final PlayerSettings settings = await boot().read(
          playerSettingsProvider.future,
        );

        expect(
          settings.osPassword,
          'hunter2',
          reason: 'the upgrade must not sign the user out',
        );
        expect(settings.subdlPassword, 'correct-horse');

        expect(keychain[kOsPasswordKey], 'hunter2');
        expect(keychain[kSubDlPasswordKey], 'correct-horse');

        expect(
          storage.getPlayerSetting<String>('player_os_pass'),
          isNull,
          reason: 'the plaintext copy in the backed-up box must be gone',
        );
        expect(storage.getPlayerSetting<String>('player_subdl_pass'), isNull);

        // The non-secret half of the same account is untouched: this moved the
        // passwords, it did not empty the settings box.
        expect(storage.getPlayerSetting<String>('player_os_user'), 'ada');
        expect(
          storage.getPlayerSetting<String>('player_subdl_email'),
          'ada@example.test',
        );
      },
    );

    test(
      'signing in writes the password to the secure store, not to Hive',
      () async {
        final ProviderContainer container = boot();
        await container.read(playerSettingsProvider.future);

        await container
            .read(playerSettingsProvider.notifier)
            .setOpenSubtitlesCredentials('ada', 'hunter2', 'os-api-key');
        await container
            .read(playerSettingsProvider.notifier)
            .setSubDlAuth(
              apiKey: 'subdl-api-key',
              email: 'ada@example.test',
              pass: 'correct-horse',
            );

        expect(keychain[kOsPasswordKey], 'hunter2');
        expect(keychain[kSubDlPasswordKey], 'correct-horse');
        expect(
          storage.getPlayerSetting<String>('player_os_pass'),
          isNull,
          reason: 'a fresh sign-in must never put the password in the box',
        );
        expect(storage.getPlayerSetting<String>('player_subdl_pass'), isNull);

        // Re-reading the settings still produces the password the user typed.
        final PlayerSettings settings = container
            .read(playerSettingsProvider)
            .requireValue;
        expect(settings.osPassword, 'hunter2');
        expect(settings.subdlPassword, 'correct-horse');
      },
    );
  });
}
