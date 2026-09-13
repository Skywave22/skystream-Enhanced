import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../storage/storage_service.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

part 'locale_provider.g.dart';

/// The locale the whole app is rendered in.
///
/// Precedence, highest first:
///
///   1. the language the user picked in Settings, which is sticky forever
///      once picked (`StorageService.getLanguage()` returns non-null);
///   2. the device's own language preference list, best match wins;
///   3. English.
///
/// (2) used to be missing entirely: storage defaulted to `'en'`, so every
/// first launch anywhere in the world came up in English and the other 42
/// translations only existed for users who went looking for them in Settings
/// - worst on Android TV, where that is a D-pad walk through a settings tree.
@Riverpod(keepAlive: true)
class LocaleNotifier extends _$LocaleNotifier {
  late final StorageService _storage;

  /// Used when neither the stored preference nor any of the device's locales
  /// is one of [AppLocalizations.supportedLocales].
  ///
  /// This has to be explicit: Flutter's own last-resort fallback is
  /// `supportedLocales.first`, which for this app is Arabic.
  static const Locale fallbackLocale = Locale('en');

  @override
  Locale build() {
    _storage = ref.read(storageServiceProvider);
    final saved = _storage.getLanguage();
    if (saved != null) return _resolveLocale(saved);
    return resolveDeviceLocale(
      WidgetsBinding.instance.platformDispatcher.locales,
    );
  }

  /// Turns a stored tag back into a supported locale.
  static Locale _resolveLocale(String langTag) {
    final parsed = _parseTag(langTag);
    // Exact match first, script and country included.
    if (AppLocalizations.supportedLocales.contains(parsed)) return parsed;
    // Fall back to language-code-only match (e.g. 'en-US' → 'en')
    final languageOnly = Locale(parsed.languageCode);
    if (AppLocalizations.supportedLocales.contains(languageOnly)) {
      return languageOnly;
    }
    // A tag we no longer ship (an old build's, a hand-edited box). Handing an
    // unsupported locale to MaterialApp resolves it to supportedLocales.first,
    // which is Arabic; English is the honest answer.
    return fallbackLocale;
  }

  /// Parses `language`, `language-COUNTRY` or `language-Script`.
  ///
  /// The script case matters for the one locale that needs it: zh-Hant is a
  /// separate translation from zh, and reading its stored tag back as a
  /// country subtag used to drop a Traditional-Chinese choice to Simplified
  /// on the next launch.
  static Locale _parseTag(String langTag) {
    final parts = langTag.split('-');
    if (parts.length < 2 || parts[1].isEmpty) return Locale(parts.first);
    final subtag = parts[1];
    final isScript =
        subtag.length == 4 &&
        subtag ==
            '${subtag[0].toUpperCase()}${subtag.substring(1).toLowerCase()}';
    return isScript
        ? Locale.fromSubtags(languageCode: parts.first, scriptCode: subtag)
        : Locale(parts.first, subtag);
  }

  /// The inverse of [_parseTag].
  @visibleForTesting
  static String tagFor(Locale locale) => [
    locale.languageCode,
    if (locale.scriptCode != null) locale.scriptCode!,
    if (locale.countryCode != null) locale.countryCode!,
  ].join('-');

  /// The best supported locale for [deviceLocales], the device's language
  /// preference list in priority order (`PlatformDispatcher.locales`).
  ///
  /// Each entry is tried in turn - the user's first choice we can actually
  /// speak wins - and English is the answer if we speak none of them.
  ///
  /// Static and public so a `MaterialApp` built outside the provider scope
  /// (the launch-failure app in main.dart) can reach the same answer instead
  /// of leaving `locale:` null, which resolves to `supportedLocales.first`.
  static Locale resolveDeviceLocale(List<Locale> deviceLocales) {
    for (final device in deviceLocales) {
      final match = _bestMatch(device);
      if (match != null) return match;
    }
    return fallbackLocale;
  }

  static Locale? _bestMatch(Locale device) {
    const supported = AppLocalizations.supportedLocales;
    // Everything the device asked for: language, script and country.
    if (supported.contains(device)) return device;
    // Language + script: zh-Hant-TW → zh-Hant.
    if (device.scriptCode != null) {
      final languageAndScript = Locale.fromSubtags(
        languageCode: device.languageCode,
        scriptCode: device.scriptCode,
      );
      if (supported.contains(languageAndScript)) return languageAndScript;
    }
    // Language + country: pt-BR → pt-BR (which is a separate translation
    // here), while pt-PT falls through to plain pt below.
    if (device.countryCode != null) {
      final languageAndCountry = Locale(
        device.languageCode,
        device.countryCode,
      );
      if (supported.contains(languageAndCountry)) return languageAndCountry;
    }
    // Traditional-Chinese regions do not always carry the script subtag, and
    // plain 'zh' here is Simplified - which a Taipei or Hong Kong user cannot
    // comfortably read.
    if (device.languageCode == 'zh' &&
        const {'TW', 'HK', 'MO'}.contains(device.countryCode)) {
      const traditional = Locale.fromSubtags(
        languageCode: 'zh',
        scriptCode: 'Hant',
      );
      if (supported.contains(traditional)) return traditional;
    }
    // Language only: de-AT → de.
    final languageOnly = Locale(device.languageCode);
    if (supported.contains(languageOnly)) return languageOnly;
    return null;
  }

  Future<void> setLocale(Locale locale) async {
    await _storage.setLanguage(tagFor(locale));
    state = locale;
  }
}
