/// Which language the app comes up in.
///
/// The app used to hardcode English on first launch: `getLanguage()` defaulted
/// to `'en'`, so "no preference recorded yet" and "the user chose English"
/// were the same value and the device's own language was never consulted. A
/// user in Berlin, Tokyo, São Paulo or Bengaluru installed the app and got
/// English, and 42 of the 43 shipped translations were unreachable without a
/// trip to Settings - a D-pad walk through a settings tree on Android TV.
///
/// These tests drive the real [StorageService] against a real Hive box in a
/// temp directory, so the "nothing recorded yet" state is the genuine one: a
/// fake would let the storage-side default quietly come back.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:skystream/core/providers/locale_provider.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late StorageService storage;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('locale_pref');
    // StorageService.init() asks path_provider where to put its boxes.
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    storage = StorageService();
    await storage.init();
  });

  tearDown(() async {
    await Hive.close();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    binding.platformDispatcher.clearLocalesTestValue();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// Boots the provider exactly as a cold start does: the real storage, and
  /// the device's language preference list as the platform reports it.
  Locale bootWith(List<Locale> deviceLocales) {
    binding.platformDispatcher.localesTestValue = deviceLocales;
    final container = ProviderContainer(
      overrides: [storageServiceProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    return container.read(localeProvider);
  }

  group('first launch, nothing recorded', () {
    test('a German device comes up in German', () {
      expect(storage.getLanguage(), isNull, reason: 'nothing recorded yet');

      expect(bootWith(const [Locale('de', 'DE')]), const Locale('de'));
    });

    test('a Japanese device comes up in Japanese', () {
      expect(bootWith(const [Locale('ja', 'JP')]), const Locale('ja'));
    });

    test('an Indian device set to Hindi comes up in Hindi', () {
      expect(
        bootWith(const [Locale('hi', 'IN'), Locale('en', 'IN')]),
        const Locale('hi'),
      );
    });

    test('a language we do not ship falls back to English', () {
      // Not to `supportedLocales.first`, which is what Flutter's own
      // last-resort resolution would pick here.
      expect(AppLocalizations.supportedLocales.first, const Locale('ar'));

      expect(bootWith(const [Locale('th', 'TH')]), const Locale('en'));
    });

    test('the first device language we do ship wins', () {
      expect(
        bootWith(const [
          Locale('is', 'IS'), // not shipped
          Locale('ja', 'JP'), // shipped
          Locale('en', 'US'),
        ]),
        const Locale('ja'),
      );
    });

    test('pt-BR gets the Brazilian translation and pt-PT gets pt', () {
      expect(bootWith(const [Locale('pt', 'BR')]), const Locale('pt', 'BR'));
      expect(bootWith(const [Locale('pt', 'PT')]), const Locale('pt'));
    });

    test('Traditional Chinese regions get zh-Hant, not Simplified', () {
      const hant = Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
      // Android reports the script subtag, and some hosts only the region.
      expect(
        bootWith(const [
          Locale.fromSubtags(
            languageCode: 'zh',
            scriptCode: 'Hant',
            countryCode: 'TW',
          ),
        ]),
        hant,
      );
      expect(bootWith(const [Locale('zh', 'TW')]), hant);
      expect(bootWith(const [Locale('zh', 'CN')]), const Locale('zh'));
    });
  });

  group('an explicit choice in Settings', () {
    test(
      'English on a German device is honoured, not treated as unset',
      () async {
        final container = ProviderContainer(
          overrides: [storageServiceProvider.overrideWithValue(storage)],
        );
        addTearDown(container.dispose);
        binding.platformDispatcher.localesTestValue = const [
          Locale('de', 'DE'),
        ];

        await container
            .read(localeProvider.notifier)
            .setLocale(const Locale('en'));

        expect(container.read(localeProvider), const Locale('en'));
        expect(storage.getLanguage(), 'en');
        // And it survives the restart that would otherwise pick up German.
        expect(bootWith(const [Locale('de', 'DE')]), const Locale('en'));
      },
    );

    test('a chosen language outranks the device', () async {
      await storage.setLanguage('fr');

      expect(bootWith(const [Locale('de', 'DE')]), const Locale('fr'));
    });

    test('Traditional Chinese survives a restart', () async {
      const hant = Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
      final container = ProviderContainer(
        overrides: [storageServiceProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);

      await container.read(localeProvider.notifier).setLocale(hant);

      // The script subtag has to survive the round trip through storage;
      // 'zh' alone reads back as Simplified.
      expect(storage.getLanguage(), 'zh-Hant');
      expect(bootWith(const [Locale('en', 'US')]), hant);
    });

    test('a stored tag we no longer ship falls back to English', () async {
      await storage.setLanguage('xx-YY');

      expect(bootWith(const [Locale('en', 'US')]), const Locale('en'));
    });

    test('a stored regional tag resolves to its language', () async {
      await storage.setLanguage('de-AT');

      expect(bootWith(const [Locale('en', 'US')]), const Locale('de'));
    });
  });

  test('every locale the resolver can return is one we ship', () {
    for (final locale in AppLocalizations.supportedLocales) {
      expect(
        LocaleNotifier.resolveDeviceLocale([locale]),
        locale,
        reason: '$locale must resolve to itself',
      );
    }
  });
}
