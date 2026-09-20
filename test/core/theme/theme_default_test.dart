/// Which theme the app comes up in when the user has never chosen one.
///
/// The app used to answer this three different ways depending on who was
/// asking: dark while [deviceProfileProvider] was still resolving, dark on a
/// television, and [ThemeMode.system] everywhere else. So a phone user who
/// never opened the theme dialog got a light app if their OS was light, and
/// the splash - which is dark - handed over to a white first frame.
///
/// Dark is now the answer in every one of those cases. An explicit choice in
/// Settings is still honoured; only "nothing recorded yet" changed.
///
/// These tests drive the real [StorageService] against a real Hive box in a
/// temp directory, so "nothing recorded yet" is the genuine state rather than
/// a fake's idea of it.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/core/theme/theme_provider.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late StorageService storage;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('theme_default');
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
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// Boots the provider the way a cold start does, with [profile] already
  /// resolved.
  ///
  /// Returning a plain [DeviceProfile] rather than a Future from the override
  /// makes the async provider settle synchronously, which is the whole point:
  /// the old code answered dark while the profile was *loading*, so a test
  /// that read the provider before it resolved would have passed against the
  /// very behaviour it was meant to change.
  ThemeMode bootWith(DeviceProfile profile) {
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        deviceProfileProvider.overrideWith((ref) => profile),
      ],
    );
    addTearDown(container.dispose);
    return container.read(appThemeModeProvider);
  }

  group('nothing chosen yet', () {
    test('a phone comes up dark', () {
      expect(storage.getThemeMode(), isNull, reason: 'nothing recorded yet');

      expect(bootWith(const DeviceProfile()), ThemeMode.dark);
    });

    test('a desktop comes up dark', () {
      expect(bootWith(const DeviceProfile(isDesktopOS: true)), ThemeMode.dark);
    });

    test('a tablet comes up dark', () {
      expect(bootWith(const DeviceProfile(isTablet: true)), ThemeMode.dark);
    });

    test('a television comes up dark', () {
      expect(bootWith(const DeviceProfile(isTv: true)), ThemeMode.dark);
    });
  });

  group('an explicit choice in Settings', () {
    test('System is honoured, not treated as unset', () async {
      await storage.saveThemeMode('system');

      expect(
        bootWith(const DeviceProfile()),
        ThemeMode.system,
        reason: 'the System option would be unselectable otherwise',
      );
    });

    test('Light is honoured on a television', () async {
      await storage.saveThemeMode('light');

      expect(bootWith(const DeviceProfile(isTv: true)), ThemeMode.light);
    });

    test('Dark is honoured', () async {
      await storage.saveThemeMode('dark');

      expect(bootWith(const DeviceProfile()), ThemeMode.dark);
    });
  });

  test('a value no release ever wrote falls back to dark', () async {
    // Storage survives downgrades and hand-editing, so an unrecognised string
    // is reachable. It means the same thing as no value at all, and should
    // land in the same place rather than quietly selecting System.
    await storage.saveThemeMode('sepia');

    expect(bootWith(const DeviceProfile()), ThemeMode.dark);
  });

  test('choosing a theme records it', () async {
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        deviceProfileProvider.overrideWith((ref) => const DeviceProfile()),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(appThemeModeProvider.notifier)
        .setThemeMode(ThemeMode.light);

    expect(container.read(appThemeModeProvider), ThemeMode.light);
    expect(storage.getThemeMode(), 'light');
  });
}
