import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Local mirror of the "Translation Coverage" step in `.github/workflows/ci.yml`.
///
/// CI reads `build/l10n_untranslated.json`, which only exists after
/// `flutter gen-l10n` has run; this test reads the ARB files directly so the
/// same rules hold on a fresh checkout and fail here, with the offending keys
/// named, before a push does. The two must stay in step: when the workflow's
/// `TOP_TIER` or `BACKLOG` change, change [_topTier] and [_backlog] too.
///
/// The rules, in the workflow's words:
///  * hi and kn are the founding, hand-authored locales and block a merge;
///    the other 39 arrived in one bulk import and only warn.
///  * A key some other locale has already translated is not shared backlog -
///    a top-tier locale missing it has fallen behind. That is why every new
///    string has to land in en, hi and kn in the same change, and why a hi-only
///    or kn-only translation trips the gate for the other one.
///  * The shared backlog may fall, never rise.
void main() {
  final Directory arbDir = Directory('lib/l10n');
  late final Map<String, Set<String>> keysByLocale = _readArbKeys(arbDir);

  test('hi and kn are missing the same keys', () {
    final Set<String> hiMissing = _missing(keysByLocale, 'hi');
    final Set<String> knMissing = _missing(keysByLocale, 'kn');
    expect(
      hiMissing,
      equals(knMissing),
      reason:
          'Translate into both top-tier locales in the same change.\n'
          'hi lacks but kn has: ${(hiMissing.difference(knMissing).toList()..sort()).join(', ')}\n'
          'kn lacks but hi has: ${(knMissing.difference(hiMissing).toList()..sort()).join(', ')}',
    );
  });

  test('top-tier locales are within the backlog ratchet', () {
    for (final String locale in _topTier) {
      final Set<String> missing = _missing(keysByLocale, locale);
      expect(
        missing.length,
        lessThanOrEqualTo(_backlog),
        reason:
            '$locale is missing ${missing.length} keys, above the $_backlog '
            'the backlog ratchet allows: ${(missing.toList()..sort()).join(', ')}',
      );
    }
  });

  test('top-tier locales are not behind any other locale', () {
    // Reproduces ci.yml's shared/behind split over the ARBs instead of the
    // gen-l10n report.
    final Iterable<Set<String>> allMissing = keysByLocale.keys
        .where((String locale) => locale != _template)
        .map((String locale) => _missing(keysByLocale, locale));
    final Set<String> shared = allMissing.reduce(
      (Set<String> a, Set<String> b) => a.intersection(b),
    );
    final Set<String> behind = allMissing
        .reduce((Set<String> a, Set<String> b) => a.union(b))
        .difference(shared);

    for (final String locale in _topTier) {
      final List<String> lagging = _missing(
        keysByLocale,
        locale,
      ).intersection(behind).toList()..sort();
      expect(
        lagging,
        isEmpty,
        reason:
            '$locale is missing ${lagging.length} key(s) other locales '
            'already have: ${lagging.join(', ')}',
      );
    }
  });

  test('every key the player consumes is present in en, hi and kn', () {
    for (final String locale in <String>[_template, ..._topTier]) {
      final Set<String> keys = keysByLocale[locale]!;
      final List<String> absent = _playerKeys
          .where((String key) => !keys.contains(key))
          .toList();
      expect(
        absent,
        isEmpty,
        reason: 'app_$locale.arb lacks: ${absent.join(', ')}',
      );
    }
  });

  test('retired keys stay retired', () {
    // A key with no call site is a claim waiting for one. Both of these were
    // removed from en, hi and kn (and, for the first, from the one bulk-import
    // locale that also carried it) in the same change that removed what they
    // said; re-adding either to any ARB brings the wording back into the
    // translation queue and, sooner or later, back onto the screen.
    //
    //  * subtitleAccountsNotConfigured told a fresh install to add an
    //    OpenSubtitles, SubDL or SubSource key before it could search. Untrue
    //    on a default install: OpenSubtitles ships a bundled key and SubSource
    //    has a keyless path. Its last call site went first, then the key.
    //  * bigPictureMode / bigPictureModeSubtitle were Steam's branding,
    //    inherited from a contributor PR. They are fullScreenMode and
    //    fullScreenModeSubtitle now.
    //  * showRotate labelled a switch in Player Controls that hid the player's
    //    manual rotate button. Orientation follows the video's own shape now,
    //    the button is gone, and the switch was moving a stored boolean that
    //    nothing read. Removing the row without the key would leave 43 locales
    //    holding a translation for a control that does not exist.
    //  * bufferDepth / selectBufferDepth titled a picker offering 1 to 20
    //    minutes of read-ahead. libVLC 3 has no read-ahead-in-seconds control
    //    for it to drive - --network-caching is per-stream output latency, and
    //    it is pinned - so every one of the twenty choices changed nothing.
    //  * wifiQualityPreference named a row whose branch is metered vs
    //    unmetered, so Ethernet, a VPN tunnel and offline playback all take
    //    it. unmeteredQualityPreference says so; the old wording sent every
    //    wired television looking for the setting under Mobile.
    for (final String key in _retired) {
      final List<String> carriers =
          keysByLocale.entries
              .where((MapEntry<String, Set<String>> e) => e.value.contains(key))
              .map((MapEntry<String, Set<String>> e) => 'app_${e.key}.arb')
              .toList()
            ..sort();
      expect(
        carriers,
        isEmpty,
        reason: '$key was retired; still in ${carriers.join(', ')}',
      );
    }
  });

  test('nothing in lib/ or test/ still reads a retired key', () {
    // The grep, as a gate. gen-l10n would not have caught this: it drops a
    // getter for every key it finds, so a stale reference only fails once the
    // key is gone - which is exactly now, and exactly once, unless something
    // keeps it honest.
    final List<String> hits = <String>[];
    for (final String root in <String>['lib', 'test']) {
      final Directory dir = Directory(root);
      for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final String relative = entity.path.replaceAll(
          Platform.pathSeparator,
          '/',
        );
        // This file names them to forbid them.
        if (relative.endsWith('test/l10n/translation_ratchet_test.dart')) {
          continue;
        }
        final List<String> lines = entity.readAsLinesSync();
        for (int i = 0; i < lines.length; i++) {
          // A reference, not a mention: a comment explaining why a key went
          // away is the documentation this gate wants to encourage.
          if (lines[i].trimLeft().startsWith('//')) continue;
          for (final String key in _retired) {
            if (lines[i].contains(key)) hits.add('$relative:${i + 1}: $key');
          }
        }
      }
    }
    expect(hits, isEmpty, reason: hits.join('\n'));
  });

  /// The player's two seek buttons are the first control in this app whose
  /// name is a NUMBER the viewer chose - the picker offers 5, 10, 15, 20, 30,
  /// 60 and 120 - so they are the first strings that can be wrong in a way a
  /// key-count ratchet cannot see: a translation that spelled the step out,
  /// or dropped the argument, still counts as present.
  ///
  /// They also landed in all 43 locales in one pass, 40 of them machine
  /// authored, which is exactly the shape of import that produces two
  /// "different" locales holding the same bytes.
  group('the seek buttons are named in every locale', () {
    late final Map<String, Map<String, String>> messages = _readArbMessages(
      arbDir,
    );
    const List<String> keys = <String>[
      'playerRewindSeconds',
      'playerForwardSeconds',
    ];

    test('every locale carries both, not just the top tier', () {
      for (final String key in keys) {
        final List<String> without =
            messages.entries
                .where(
                  (MapEntry<String, Map<String, String>> e) =>
                      !e.value.containsKey(key),
                )
                .map((MapEntry<String, Map<String, String>> e) => e.key)
                .toList()
              ..sort();
        expect(
          without,
          isEmpty,
          reason:
              '$key is a tooltip on a button every platform draws; '
              'app_${without.join('.arb, app_')}.arb would fall back to '
              'English on it',
        );
      }
    });

    test('the step is an argument, not a number written into the text', () {
      for (final MapEntry<String, Map<String, String>> locale
          in messages.entries) {
        for (final String key in keys) {
          final String? message = locale.value[key];
          if (message == null) continue;
          expect(
            message,
            startsWith('{count, plural,'),
            reason:
                'app_${locale.key}.arb $key must be a plural: several of '
                'these languages inflect the noun after a numeral',
          );
          expect(
            message,
            contains('{count}'),
            reason:
                'app_${locale.key}.arb $key never interpolates the step, so '
                'it says the same thing at 5 s and at 120 s',
          );
        }
      }
    });

    test('rewind and forward do not say the same thing', () {
      for (final MapEntry<String, Map<String, String>> locale
          in messages.entries) {
        final String? rewind = locale.value[keys.first];
        final String? forward = locale.value[keys.last];
        if (rewind == null || forward == null) continue;
        expect(
          rewind,
          isNot(equals(forward)),
          reason:
              'app_${locale.key}.arb names both directions the same, which '
              'is the copy-paste this pair is most exposed to',
        );
      }
    });

    // The classic bulk-import collisions. A locale that exists only because
    // its parent could not serve it has to differ from its parent, or the
    // file is a claim nobody is honouring: ar_apc is spoken Levantine against
    // Modern Standard Arabic, zh_Hant is Traditional against Simplified, and
    // pt_BR is Brazilian against European Portuguese.
    //
    // Rewind is the discriminator for all three because it is where the
    // varieties genuinely part - recuar/voltar, 快退/倒轉, تأخير/رجّع.
    // playerForwardSeconds is deliberately identical in pt and pt_BR:
    // "Avançar" is the standard verb on both sides of the Atlantic, and
    // forcing a difference there would be inventing one.
    test('a variety is not a copy of the locale it exists to differ from', () {
      for (final (String parent, String variety) in <(String, String)>[
        ('ar', 'ar_apc'),
        ('zh', 'zh_Hant'),
        ('pt', 'pt_BR'),
      ]) {
        expect(
          messages[variety]!['playerRewindSeconds'],
          isNot(equals(messages[parent]!['playerRewindSeconds'])),
          reason:
              'app_$variety.arb repeats app_$parent.arb byte for byte on '
              'playerRewindSeconds',
        );
      }
    });
  });

  test('the ARB template is the superset of every locale', () {
    // A key in a translation but not in en is dead weight gen-l10n ignores;
    // usually a typo in the key name that silently leaves the English in place.
    final Set<String> template = keysByLocale[_template]!;
    for (final MapEntry<String, Set<String>> entry in keysByLocale.entries) {
      final List<String> extra = entry.value.difference(template).toList()
        ..sort();
      expect(
        extra,
        isEmpty,
        reason:
            'app_${entry.key}.arb has keys en does not: ${extra.join(', ')}',
      );
    }
  });
}

/// Locale codes ci.yml treats as blocking (`TOP_TIER`).
const Set<String> _topTier = <String>{'hi', 'kn'};

/// Most keys a top-tier locale may lack (`BACKLOG`). Falls, never rises.
const int _backlog = 62;

const String _template = 'en';

/// Keys the Phase 2 player work reads; a rename or removal in en must show up
/// here rather than as a runtime English fallback in hi or kn.
const List<String> _playerKeys = <String>[
  'audioDelay',
  'playerRewindSeconds',
  'playerForwardSeconds',
  'subtitleSearchTitleFallback',
  'audioTracks',
  'episodes',
  'live',
  'off',
  'retry',
];

/// Keys deleted on purpose, kept here so that deleting them stays deleted.
const List<String> _retired = <String>[
  'subtitleAccountsNotConfigured',
  'bigPictureMode',
  'bigPictureModeSubtitle',
  'showRotate',
  'bufferDepth',
  'selectBufferDepth',
  'wifiQualityPreference',
];

/// Message strings per locale, `@@locale` and `@key` metadata dropped.
///
/// [_readArbKeys]'s sibling: that one answers "is the key there", which is all
/// the ratchet needs, and this one answers "and does it say anything".
Map<String, Map<String, String>> _readArbMessages(Directory arbDir) {
  final RegExp name = RegExp(r'^app_(.+)\.arb$');
  final Map<String, Map<String, String>> result =
      <String, Map<String, String>>{};
  for (final FileSystemEntity entity in arbDir.listSync()) {
    if (entity is! File) continue;
    final RegExpMatch? match = name.firstMatch(entity.uri.pathSegments.last);
    if (match == null) continue;
    final Map<String, dynamic> arb =
        jsonDecode(entity.readAsStringSync()) as Map<String, dynamic>;
    result[match.group(1)!] = <String, String>{
      for (final MapEntry<String, dynamic> e in arb.entries)
        if (!e.key.startsWith('@') && e.value is String)
          e.key: e.value as String,
    };
  }
  return result;
}

Set<String> _missing(Map<String, Set<String>> keysByLocale, String locale) {
  final Set<String>? keys = keysByLocale[locale];
  expect(keys, isNotNull, reason: 'no app_$locale.arb under lib/l10n');
  return keysByLocale[_template]!.difference(keys!);
}

/// Message keys per locale, `@@locale` and `@key` metadata dropped, keyed by
/// the locale suffix of the file name (`app_pt_BR.arb` -> `pt_BR`).
Map<String, Set<String>> _readArbKeys(Directory arbDir) {
  expect(
    arbDir.existsSync(),
    isTrue,
    reason: 'run this from the package root so lib/l10n resolves',
  );
  final RegExp name = RegExp(r'^app_(.+)\.arb$');
  final Map<String, Set<String>> result = <String, Set<String>>{};
  for (final FileSystemEntity entity in arbDir.listSync()) {
    if (entity is! File) continue;
    final RegExpMatch? match = name.firstMatch(entity.uri.pathSegments.last);
    if (match == null) continue;
    final Map<String, dynamic> arb =
        jsonDecode(entity.readAsStringSync()) as Map<String, dynamic>;
    result[match.group(1)!] = arb.keys
        .where((String key) => !key.startsWith('@'))
        .toSet();
  }
  expect(result, contains(_template));
  return result;
}
