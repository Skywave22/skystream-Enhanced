import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../storage/settings_repository.dart';

part 'theme_provider.g.dart';

@Riverpod(keepAlive: true)
class AppThemeMode extends _$AppThemeMode {
  late SettingsRepository _repository;

  @override
  ThemeMode build() {
    _repository = ref.watch(settingsRepositoryProvider);
    final saved = _repository.getThemeMode();
    // Dark is the app's default, not a per-device guess. This used to branch
    // on [deviceProfileProvider] - dark while it was still resolving, dark on
    // a television, system everywhere else - which meant the splash, which is
    // dark, handed over to a white first frame on a light-themed phone, and
    // the answer changed halfway through boot as the profile arrived.
    // System is still one click away in Settings; it is just no longer what
    // you get without asking.
    if (saved == null) return ThemeMode.dark;
    return _getThemeMode(saved);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    await _repository.saveThemeMode(mode.name);
  }

  ThemeMode _getThemeMode(String mode) {
    switch (mode) {
      case 'light':
        return ThemeMode.light;
      case 'system':
        return ThemeMode.system;
      // 'dark', and anything no release ever wrote. Storage outlives
      // downgrades and hand-editing, so an unrecognised value is reachable; it
      // says no more than an absent one does, and lands in the same place.
      case 'dark':
      default:
        return ThemeMode.dark;
    }
  }
}
