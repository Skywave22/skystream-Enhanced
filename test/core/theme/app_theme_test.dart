import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/theme/app_theme.dart';
import 'package:skystream/features/player/presentation/widgets/hotstar_player_style.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('dark SnackBars use the application surface colors', () {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppTheme.primary,
      brightness: Brightness.dark,
    );
    final theme = AppTheme.snackBarThemeFor(colorScheme);

    expect(theme.backgroundColor, AppTheme.surface);
    expect(theme.contentTextStyle?.color, AppTheme.onSurface);
  });

  test(
    'light SnackBars use nearby surface colors instead of inverse colors',
    () {
      final colorScheme = ColorScheme.fromSeed(seedColor: AppTheme.lightCoral);
      final theme = AppTheme.snackBarThemeFor(colorScheme);

      expect(theme.backgroundColor, colorScheme.surfaceContainerHigh);
      expect(theme.contentTextStyle?.color, colorScheme.onSurface);
    },
  );

  /// The type family used to be fetched from fonts.gstatic.com on first
  /// launch by `google_fonts`. Two things were wrong with that: a first launch
  /// with no network - a TV box before Wi-Fi is configured, a plane, a captive
  /// portal - rendered the entire app in a fallback face, and every first
  /// launch made a request to a third-party server before the user had done
  /// anything at all. The family is now bundled.
  group('bundled type family', () {
    /// Spelled out rather than read from `AppTheme`, so that renaming the
    /// constant cannot quietly move the goalposts.
    const family = 'Outfit';

    /// The weights the app asks for: 400/500/600/700 from the text theme,
    /// 800/900 from widget-level overrides. Anything else Flutter snaps to
    /// the nearest of these.
    const shippedWeights = {400, 500, 600, 700, 800, 900};

    test('both themes typeset in the bundled family', () {
      for (final theme in [
        AppTheme.createDarkTheme(null),
        AppTheme.createLightTheme(null),
      ]) {
        final styles = <String, TextStyle?>{
          'displayLarge': theme.textTheme.displayLarge,
          'titleLarge': theme.textTheme.titleLarge,
          'bodyLarge': theme.textTheme.bodyLarge,
          'bodyMedium': theme.textTheme.bodyMedium,
          'bodySmall': theme.textTheme.bodySmall,
          'labelSmall': theme.textTheme.labelSmall,
          'dialog title': theme.dialogTheme.titleTextStyle,
        };
        styles.forEach((role, style) {
          expect(
            style?.fontFamily,
            family,
            reason:
                '$role (${theme.brightness}) must name the bundled family, '
                'not a family that is registered only after a download',
          );
          expect(
            style?.fontFamilyFallback ?? const <String>[],
            isEmpty,
            reason:
                '$role (${theme.brightness}) falls back to a family that only '
                'exists once something has been downloaded',
          );
        });
      }
    });

    test(
      'the family is declared in the bundle with the weights used',
      () async {
        final manifest =
            (jsonDecode(await rootBundle.loadString('FontManifest.json'))
                    as List<dynamic>)
                .cast<Map<String, dynamic>>();
        final outfit = manifest.firstWhere(
          (family) => family['family'] == 'Outfit',
          orElse: () => throw TestFailure(
            'no $family family in FontManifest.json: the '
            '`fonts:` section of pubspec.yaml is missing, so the app would be '
            'back to downloading a face it cannot draw offline. Manifest: '
            '$manifest',
          ),
        );
        final fonts = (outfit['fonts'] as List<dynamic>)
            .cast<Map<String, dynamic>>();

        expect(
          fonts.map((font) => font['weight']).toSet(),
          shippedWeights,
          reason: 'the weights the app asks for, and no more',
        );

        // Declared is not shipped: load the bytes and check they are a font.
        for (final font in fonts) {
          final asset = font['asset'] as String;
          final bytes = await rootBundle.load(asset);
          expect(bytes.lengthInBytes, greaterThan(1000), reason: asset);
          expect(
            bytes.getUint32(0),
            anyOf(0x00010000, 0x74727565, 0x4F54544F),
            reason: '$asset is not a TrueType/OpenType file',
          );
        }
      },
    );

    test('the OFL licence text ships beside the font', () async {
      // SIL OFL 1.1 permits bundling the font inside an application; it also
      // requires the licence to travel with it.
      final licence = await rootBundle.loadString('assets/fonts/OFL.txt');
      expect(licence, contains('SIL OPEN FONT LICENSE Version 1.1'));
      expect(licence, contains('The Outfit Project Authors'));
    });

    test('nothing in lib/ fetches a font at runtime', () {
      final lib = Directory('lib');
      expect(
        lib.existsSync(),
        isTrue,
        reason: 'run this from the package root so lib/ resolves',
      );
      final offenders = <String>[];
      for (final entity in lib.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = entity.readAsStringSync();
        if (source.contains('package:google_fonts') ||
            source.contains('GoogleFonts.')) {
          offenders.add(entity.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'these download the type ramp on first launch',
      );

      expect(
        File(
          'pubspec.yaml',
        ).readAsLinesSync().where((line) => line.startsWith('  google_fonts:')),
        isEmpty,
        reason: 'the dependency is gone; keep it gone',
      );
    });
  });

  /// WCAG 2.2 contrast, computed rather than eyeballed.
  ///
  /// `bodySmall` is the subtitle line under every settings tile - the line
  /// that states the *current value* of the setting - so it is the app's most
  /// repeated piece of secondary text. It used to measure 4.34:1 in dark and
  /// 3.81:1 in light against the scaffold, both under the 4.5:1 that AA asks
  /// of text below 18 pt.
  group('contrast', () {
    /// sRGB relative luminance, WCAG 2.x definition.
    double luminance(Color c) {
      double channel(double v) => v <= 0.03928
          ? v / 12.92
          : math.pow((v + 0.055) / 1.055, 2.4) as double;
      return 0.2126 * channel(c.r) +
          0.7152 * channel(c.g) +
          0.0722 * channel(c.b);
    }

    /// [fg] painted over opaque [bg]. Alpha is part of the contrast: a colour
    /// at 80% alpha is not the colour the eye receives.
    Color composite(Color fg, Color bg) => Color.from(
      alpha: 1,
      red: fg.r * fg.a + bg.r * (1 - fg.a),
      green: fg.g * fg.a + bg.g * (1 - fg.a),
      blue: fg.b * fg.a + bg.b * (1 - fg.a),
    );

    double contrast(Color fg, Color bg) {
      final a = luminance(composite(fg, bg));
      final b = luminance(bg);
      final hi = math.max(a, b);
      final lo = math.min(a, b);
      return (hi + 0.05) / (lo + 0.05);
    }

    void expectAtLeast(double actual, double required, String what) {
      expect(
        actual,
        greaterThanOrEqualTo(required),
        reason:
            '$what measures ${actual.toStringAsFixed(2)}:1, WCAG asks for '
            '${required.toStringAsFixed(1)}:1',
      );
    }

    /// The helper agrees with the published worked examples before it is
    /// trusted to grade the theme.
    test('the ratio helper matches known values', () {
      expect(
        contrast(const Color(0xFFFFFFFF), const Color(0xFF000000)),
        closeTo(21, 0.01),
      );
      expect(
        contrast(const Color(0xFF777777), const Color(0xFFFFFFFF)),
        closeTo(4.48, 0.01),
      );
      // Alpha is honoured: white at 50% over black is the same as #808080.
      expect(
        contrast(const Color(0x80FFFFFF), const Color(0xFF000000)),
        closeTo(
          contrast(const Color(0xFF808080), const Color(0xFF000000)),
          0.02,
        ),
      );
    });

    for (final (name, theme) in [
      ('dark', AppTheme.createDarkTheme(null)),
      ('light', AppTheme.createLightTheme(null)),
    ]) {
      test('$name bodySmall clears AA on every surface it lands on', () {
        final style = theme.textTheme.bodySmall!;
        expect(
          style.fontSize,
          lessThan(18),
          reason: 'AA large-text would not apply',
        );
        // The four backgrounds a settings subtitle is actually painted on.
        // `surfaceContainerHighest` is deliberately not in this list: the
        // dark scheme derives it from the seed and it comes out light enough
        // (0xFF36343B) that no colour readable on the pure-black scaffold can
        // also clear 4.5:1 on it. Nothing renders bodySmall there today; a
        // widget that starts to owes its own foreground.
        final surfaces = <String, Color>{
          'scaffold': theme.scaffoldBackgroundColor,
          'card': theme.cardTheme.color ?? theme.colorScheme.surface,
          'dialog':
              theme.dialogTheme.backgroundColor ?? theme.colorScheme.surface,
          'bottom sheet':
              theme.bottomSheetTheme.backgroundColor ??
              theme.colorScheme.surface,
        };
        surfaces.forEach((where, background) {
          expectAtLeast(
            contrast(style.color!, background),
            4.5,
            '$name bodySmall on the $where',
          );
        });
      });
    }

    /// The player chrome floats over video behind a scrim whose darkest stop
    /// is [HotstarPlayerStyle.background]; the panels are painted with it.
    test('player chrome text and tracks clear their thresholds', () {
      const under = [
        HotstarPlayerStyle.background,
        HotstarPlayerStyle.panel,
        HotstarPlayerStyle.panelElevated,
      ];
      for (final background in under) {
        expectAtLeast(
          contrast(HotstarPlayerStyle.mutedText, background),
          4.5,
          'HotstarPlayerStyle.mutedText on $background',
        );
        expectAtLeast(
          contrast(HotstarPlayerStyle.secondaryText, background),
          4.5,
          'HotstarPlayerStyle.secondaryText on $background',
        );
        // Non-text: the unfilled part of a progress track is what tells the
        // viewer how much is left, so WCAG 1.4.11 asks 3:1 of it.
        expectAtLeast(
          contrast(HotstarPlayerStyle.trackInactive, background),
          3.0,
          'HotstarPlayerStyle.trackInactive on $background',
        );
      }
    });
  });
}
