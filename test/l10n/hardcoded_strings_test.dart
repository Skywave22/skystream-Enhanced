import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the ARB migration against backsliding.
///
/// Every user-visible string in the app is supposed to come from
/// `AppLocalizations`; 41 locales are worthless if new screens keep hardcoding
/// English. This walks `lib/` for the literal shapes that reach a user - a
/// `Text('...')`, a `tooltip:`, a `label:`/`labelText:`, a `hintText:`, the
/// `content: Text('...')` of a SnackBar - and holds the count against a
/// per-file budget recorded from the tree as it stood when the gate landed.
///
/// The budget is a ratchet, not an allowlist of forgiveness. A file may come
/// in under its number (that is the direction we want and the test says so out
/// loud), it may never go over, and a file with no entry must be at zero. That
/// is deliberately per-file rather than per-directory: excluding
/// `lib/features/settings/**` wholesale would hide the next screen somebody
/// writes in there, which is exactly the failure this exists to catch.
///
/// Debug output is not user-visible, so `debugPrint`, `assert`, `talker`,
/// `kDebugMode` and `dart:developer` lines are skipped by pattern rather than
/// by exempting whole files - a file is allowed to log in English and still be
/// held to the standard for what it renders.
///
/// Not covered here, on purpose: `subtitle_search_provider.dart` carries ~40
/// English language NAMES ("Portuguese (Brazilian)", "Simplified Chinese").
/// Those are display names for a locale list, which is an Intl/CLDR job -
/// `LocaleNames`, keyed off the user's locale - and not 40 more ARB keys.
/// They live in a `const` map rather than a widget argument, so they do not
/// trip the patterns below; leave them for that separate piece of work.
void main() {
  test('no new hardcoded user-visible strings in lib/', () {
    final Directory lib = Directory('lib');
    expect(
      lib.existsSync(),
      isTrue,
      reason: 'run this from the package root so lib/ resolves',
    );

    final Map<String, int> found = <String, int>{};
    final Map<String, List<String>> samples = <String, List<String>>{};

    for (final FileSystemEntity entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // gen-l10n output is generated English; it is the source, not a leak.
      if (entity.path.contains('${Platform.pathSeparator}generated${Platform.pathSeparator}')) {
        continue;
      }

      final String relative = entity.path.replaceAll(Platform.pathSeparator, '/');
      final List<String> lines = entity.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        final String line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        if (_debugOnly.hasMatch(line)) continue;

        for (final RegExp pattern in _widgetStringPatterns) {
          for (final RegExpMatch match in pattern.allMatches(line)) {
            final String literal = match.group(2)!;
            if (!_isProse(literal)) continue;
            found[relative] = (found[relative] ?? 0) + 1;
            (samples[relative] ??= <String>[]).add('${i + 1}: $literal');
          }
        }
      }
    }

    final List<String> failures = <String>[];
    final List<String> improved = <String>[];

    for (final MapEntry<String, int> entry in found.entries) {
      final int budget = _budget[entry.key] ?? 0;
      if (entry.value > budget) {
        failures.add(
          '${entry.key}: ${entry.value} hardcoded strings, budget $budget\n'
          '    ${samples[entry.key]!.join('\n    ')}',
        );
      }
    }
    for (final MapEntry<String, int> entry in _budget.entries) {
      final int actual = found[entry.key] ?? 0;
      if (actual < entry.value) {
        improved.add('${entry.key}: ${entry.value} -> $actual');
      }
    }

    // A whole-repo ceiling as well as per-file ones: moving a hardcoded string
    // from a budgeted file into a budgeted neighbour is not progress.
    final int total = found.values.fold(0, (int a, int b) => a + b);
    if (total > _totalBudget) {
      failures.add('$total hardcoded strings in lib/, ceiling $_totalBudget');
    }

    if (improved.isNotEmpty) {
      // ignore: avoid_print
      print(
        'Hardcoded strings removed - lower these budgets in '
        'test/l10n/hardcoded_strings_test.dart:\n  ${improved.join('\n  ')}',
      );
    }

    expect(
      failures,
      isEmpty,
      reason:
          'New user-visible strings must go through AppLocalizations. Add a key '
          'to lib/l10n/app_en.arb and read it via AppLocalizations.of(context). '
          'If a match is genuinely not prose (a URL, an id, a number) widen '
          '_isProse rather than raising a budget.\n\n${failures.join('\n')}',
    );
  });
}

/// Argument positions whose string ends up on screen. Group 1 is the quote so
/// group 2 can backreference it and stop at the matching close quote.
final List<RegExp> _widgetStringPatterns = <RegExp>[
  RegExp(r"""\bText\(\s*(['"])((?:\\.|(?!\1).)*)\1"""),
  RegExp(r"""\btooltip:\s*(['"])((?:\\.|(?!\1).)*)\1"""),
  RegExp(r"""\blabel(?:Text)?:\s*(['"])((?:\\.|(?!\1).)*)\1"""),
  RegExp(r"""\bhint(?:Text)?:\s*(['"])((?:\\.|(?!\1).)*)\1"""),
  RegExp(r"""\b(?:helperText|errorText):\s*(['"])((?:\\.|(?!\1).)*)\1"""),
  RegExp(r"""\bsemanticLabel:\s*(['"])((?:\\.|(?!\1).)*)\1"""),
];

/// Lines that only ever reach a console. Matched on the line, not the file, so
/// a screen that logs in English is still policed for what it renders.
final RegExp _debugOnly = RegExp(
  r'debugPrint|assert\(|talker|kDebugMode|developer\.log|\bprint\(',
);

final RegExp _interpolation = RegExp(r'\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*');
final RegExp _word = RegExp(r'[A-Za-z]{2,}');

/// True when a literal is English prose a translator would need.
///
/// `'$rangeStart-$rangeEnd'`, `'${volume}%'` and `'🍿'` carry no words once the
/// interpolations are removed. `'1.1.1.1'`, `'dns.adguard.com'` and
/// `'https://example.strem.io/manifest.json'` are addresses: an unbroken token
/// containing a dot or a slash is an identifier, not a sentence.
bool _isProse(String literal) {
  final String core = literal.replaceAll(_interpolation, '').trim();
  if (!_word.hasMatch(core)) return false;
  if (!core.contains(' ') && (core.contains('.') || core.contains('/'))) {
    return false;
  }
  return true;
}

/// Ceiling for the whole of `lib/`, recorded when this gate landed.
const int _totalBudget = 146;

/// Per-file counts as of the ARB migration. Lower them as strings move into
/// app_en.arb; never raise one.
const Map<String, int> _budget = <String, int>{
  // macOS PlatformMenuBar items - real UI, still English.
  'lib/main.dart': 9,
  'lib/features/addons/presentation/addon_catalog_screen.dart': 1,
  'lib/features/addons/presentation/addon_detail_screen.dart': 2,
  'lib/features/addons/presentation/addon_sources_sheet.dart': 13,
  'lib/features/addons/presentation/addons_screen.dart': 6,
  'lib/features/addons/presentation/widgets/addon_manage_view.dart': 19,
  'lib/features/details/presentation/details_screen.dart': 4,
  'lib/features/details/presentation/widgets/episode_picker_sheet.dart': 1,
  'lib/features/explore/presentation/anilist_explore_screen.dart': 1,
  'lib/features/explore/presentation/explore_screen.dart': 1,
  'lib/features/explore/presentation/widgets/explore_mode_selector_dialog.dart': 2,
  'lib/features/extensions/screens/extensions_screen.dart': 1,
  'lib/features/extensions/screens/plugin_settings_screen.dart': 4,
  'lib/features/home/presentation/delegates/home_search_delegate.dart': 1,
  'lib/features/home/presentation/home_screen.dart': 1,
  'lib/features/library/presentation/widgets/downloads_tab.dart': 7,
  'lib/features/nuvio/presentation/nuvio_plugins_screen.dart': 1,
  'lib/features/nuvio/presentation/nuvio_plugins_view.dart': 13,
  'lib/features/nuvio/presentation/nuvio_scraper_settings_dialog.dart': 4,
  'lib/features/search/presentation/search_screen.dart': 3,
  'lib/features/settings/presentation/account_settings_screen.dart': 2,
  'lib/features/settings/presentation/widgets/settings_dialogs.dart': 29,
  'lib/features/settings/presentation/widgets/tracking_auth_dialog.dart': 2,
  'lib/features/settings/presentation/widgets/webview_auth_dialog.dart': 5,
  'lib/features/sources/presentation/plugin_sources_sheet.dart': 14,
};
