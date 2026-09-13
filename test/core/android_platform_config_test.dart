// Audit W25 + W26 — the parts of the Android app that live in XML and Kotlin,
// where no widget test can reach them.
//
// These are source guards, and they are honest about it: they pin the text of
// the manifest, the two themes, the backup rules and MainActivity, not the
// behaviour of a device. Each one is here because the defect it describes was
// found in the tree and would come back silently, with nothing else in the
// suite noticing:
//
//   * the cutout attribute was in values/styles.xml and missing from
//     values-night/styles.xml, so the same handset showed a different amount
//     of picture depending on a theme setting;
//   * the app had no backup rules at all, so the flutter_secure_storage
//     ciphertext went to Google Drive and came back undecryptable;
//   * the PiP media-control receiver was registered RECEIVER_EXPORTED under a
//     bare "media_control" action, which any app on the device could send.
//
// Verified on a built APK as well — see the merged manifest and the resource
// table dumped from app-debug.apk — because a text match is not proof that
// the resource compiler agreed.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _manifest = 'android/app/src/main/AndroidManifest.xml';
const String _lightStyles = 'android/app/src/main/res/values/styles.xml';
const String _darkStyles = 'android/app/src/main/res/values-night/styles.xml';
const String _backupRules = 'android/app/src/main/res/xml/backup_rules.xml';
const String _extractionRules =
    'android/app/src/main/res/xml/data_extraction_rules.xml';
const String _mainActivity =
    'android/app/src/main/kotlin/dev/akash/cloudstream/MainActivity.kt';

String _read(String path) {
  final File file = File(path);
  expect(file.existsSync(), isTrue, reason: '$path is missing');
  return file.readAsStringSync();
}

/// The body of `<style name="NormalTheme" ...>` in [source].
String _normalTheme(String source) {
  final int start = source.indexOf('<style name="NormalTheme"');
  expect(start, isNonNegative, reason: 'NormalTheme not found');
  final int end = source.indexOf('</style>', start);
  expect(end, greaterThan(start), reason: 'NormalTheme not closed');
  return source.substring(start, end);
}

void main() {
  group('display cutout', () {
    test('light and dark NormalTheme agree about the cutout', () {
      const String attribute = 'android:windowLayoutInDisplayCutoutMode';

      final String light = _normalTheme(_read(_lightStyles));
      final String dark = _normalTheme(_read(_darkStyles));

      expect(
        light,
        contains(attribute),
        reason: 'the light theme is the one that was already right',
      );
      expect(
        dark,
        contains(attribute),
        reason:
            'without it, fullscreen video on a notched or punch-hole phone is '
            'letterboxed away from the cutout in dark mode and not in light '
            'mode — the same phone, the same film, two different pictures',
      );
      expect(
        RegExp('$attribute">([a-zA-Z]+)<').firstMatch(dark)?.group(1),
        RegExp('$attribute">([a-zA-Z]+)<').firstMatch(light)?.group(1),
        reason: 'and they must agree on the value, not merely both set it',
      );
    });
  });

  group('data at rest', () {
    test('the application declares both backup rule files', () {
      final String manifest = _read(_manifest);
      expect(
        manifest,
        contains('android:fullBackupContent="@xml/backup_rules"'),
      );
      expect(
        manifest,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
      );
    });

    test('secure storage is excluded from backup and device transfer', () {
      // The values file holds the credential ciphertext; the key file holds
      // the AES key wrapped by an Android Keystore key that never leaves the
      // device, so a restored copy is not merely a leak, it is undecryptable
      // and produces a silent signed-out state on the new handset.
      const List<String> prefsFiles = <String>[
        'FlutterSecureStorage.xml',
        'FlutterSecureKeyStorage.xml',
      ];

      final String legacy = _read(_backupRules);
      for (final String prefs in prefsFiles) {
        expect(
          legacy,
          contains('<exclude domain="sharedpref" path="$prefs" />'),
          reason: 'Android 11 and below back up $prefs without this',
        );
      }

      final String modern = _read(_extractionRules);
      for (final String section in <String>[
        'cloud-backup',
        'device-transfer',
      ]) {
        final int start = modern.indexOf('<$section>');
        final int end = modern.indexOf('</$section>');
        expect(start, isNonNegative, reason: '<$section> missing');
        expect(end, greaterThan(start));
        final String body = modern.substring(start, end);
        for (final String prefs in prefsFiles) {
          expect(
            body,
            contains('<exclude domain="sharedpref" path="$prefs" />'),
            reason: '$prefs is still carried by $section',
          );
        }
      }
    });
  });

  group('the picture-in-picture media control receiver', () {
    test('is registered not-exported, under a namespaced action', () {
      final String source = _read(_mainActivity);

      expect(
        source,
        contains('ContextCompat.RECEIVER_NOT_EXPORTED'),
        reason:
            'an exported receiver lets any app on the device pause, resume or '
            'seek the film the user is watching',
      );
      expect(
        source,
        isNot(contains('RECEIVER_EXPORTED')),
        reason: 'RECEIVER_NOT_EXPORTED is a distinct constant; both is neither',
      );
      expect(
        source,
        contains('ACTION_MEDIA_CONTROL = "dev.akash.skystream.MEDIA_CONTROL"'),
        reason:
            'a bare "media_control" action is a name any other app can guess '
            'and, on Android 12 and below, send',
      );
    });

    test('no component other than the launcher activity is exported', () {
      final String manifest = _read(_manifest);

      // Every exported="true" in the file, with the tag it sits in.
      final Iterable<String> exported = RegExp(
        r'<(activity|service|receiver|provider)\b[^>]*?'
        r'android:exported="true"',
        dotAll: true,
      ).allMatches(manifest).map((RegExpMatch m) => m.group(0)!);

      expect(
        exported.length,
        1,
        reason:
            'exactly one component is reachable from outside the app: '
            'MainActivity, which has to be, because it is the launcher. '
            'Found: $exported',
      );
      expect(exported.single, contains('.MainActivity'));
    });
  });

  group('picture-in-picture window shape', () {
    test('MainActivity shapes the window from the video size', () {
      // A source guard, not a behavioural one: the aspect ratio only exists on
      // a device. It is here because the Dart half is pinned by
      // player_platform_service_test and this is the other end of the same
      // wire — arguments that arrive and are then dropped would look green.
      final String source = _read(_mainActivity);

      expect(source, contains('builder.setAspectRatio(it)'));
      expect(
        source,
        contains("call.argument<Int>(\"videoWidth\")"),
        reason: 'the width Dart sends must actually be read',
      );
      expect(source, contains("call.argument<Int>(\"videoHeight\")"));
      expect(
        source,
        contains('coerceIn(1.0 / MAX_PIP_ASPECT, MAX_PIP_ASPECT)'),
        reason:
            'Android throws IllegalArgumentException out of '
            'enterPictureInPictureMode for a ratio beyond ~2.39:1, so an '
            'unclamped 2.76:1 transfer would crash the app entering PiP',
      );
    });
  });
}
