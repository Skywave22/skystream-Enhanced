import 'package:flutter/foundation.dart'
    show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

class AppTheme {
  /// The bundled application type family.
  ///
  /// The whole ramp used to come from the google_fonts package, which
  /// downloads the .ttf from fonts.gstatic.com on first launch: with no
  /// network the app rendered in a fallback face, and every first launch
  /// reached out to a third-party server before the user had done anything.
  /// The six weights the app uses are now declared in pubspec.yaml under
  /// `fonts:`.
  static const String fontFamily = 'Outfit';

  /// Fonts that ship as bundle assets are not registered with Flutter's
  /// licence registry the way a package's LICENSE file is, so the SIL Open
  /// Font License text that travels with Outfit is registered here. The
  /// package it replaced did the equivalent at runtime; the in-app licence
  /// page keeps showing the entry without it.
  static bool _fontLicenceRegistered = false;

  static void _registerFontLicence() {
    if (_fontLicenceRegistered) return;
    _fontLicenceRegistered = true;
    LicenseRegistry.addLicense(() async* {
      yield LicenseEntryWithLineBreaks(const <String>[
        fontFamily,
      ], await rootBundle.loadString('assets/fonts/OFL.txt'));
    });
  }

  // Premium Colors
  static const Color background = Color(0xFF0F0F13); // Deep dark blue-grey
  static const Color surface = Color(0xFF18181F);
  static const Color surfaceHighlight = Color(0xFF22222E);
  static const Color primary = Color(0xFF448AFF); // Blue Accent
  static const Color primaryVariant = Color(0xFF2962FF); // Blue Accent Darker
  static const Color secondary = Color(0xFF10B981); // Emerald
  static const Color error = Color(0xFFEF4444);
  static const Color onSurface = Color(0xFFE5E7EB);
  static const Color textSecondary = Color(0xFF9CA3AF);

  // Light Theme Colors
  static const Color lightBackground = Color(0xFFF5F1EC); // primary surface
  static const Color lightSurface = Color(0xFFFAF8F5); // surfaceContainerLowest
  static const Color lightSurfaceHighlight = Color(
    0xFFE8E2D8,
  ); // surfaceContainerHigh
  static const Color lightTextPrimary = Color(0xFF2C2521); // onSurface
  static const Color lightTextSecondary = Color(0xFF5C5C5C); // onSurfaceVariant
  static const Color lightCoral = Color(0xFFC63523); // Coral Accent

  static SnackBarThemeData snackBarThemeFor(ColorScheme colorScheme) {
    final isDark = colorScheme.brightness == Brightness.dark;
    return SnackBarThemeData(
      backgroundColor: isDark ? surface : colorScheme.surfaceContainerHigh,
      contentTextStyle: TextStyle(
        color: isDark ? onSurface : colorScheme.onSurface,
      ),
      actionTextColor: colorScheme.primary,
    );
  }

  static ThemeData createDarkTheme(ColorScheme? dynamicScheme) {
    _registerFontLicence();
    var colorScheme =
        dynamicScheme ??
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF448AFF), // Blue Accent seed
          brightness: Brightness.dark,
          surface: const Color(0xFF000000), // Default surface
        );

    // Ensure surface is always Pitch Black for list items/cards
    colorScheme = colorScheme.copyWith(surface: const Color(0xFF000000));

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: const Color(
        0xFF000000,
      ), // Pure Black Background for Screens
      // Dialog Theme (Premium Grey)
      dialogTheme: const DialogThemeData(
        backgroundColor: Color(0xFF18181F),
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: Color(0xFFF9FAFB),
        ),
      ),

      // Bottom Sheet Theme (Premium Grey)
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Color(0xFF18181F),
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: Color(0xFF18181F),
      ),

      // Card Theme (Pitch Black for List Items)
      cardTheme: const CardThemeData(
        color: Color(0xFF000000),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),

      // Material 3 Color Scheme
      colorScheme: colorScheme,

      // Typography
      textTheme: ThemeData.dark().textTheme
          .apply(fontFamily: fontFamily)
          .copyWith(
            displayLarge: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: Color(0xFFF9FAFB),
            ),
            displayMedium: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: Color(0xFFF9FAFB),
            ),
            displaySmall: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Color(0xFFF9FAFB),
            ),
            headlineMedium: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 24,
              fontWeight: FontWeight.w600,
              color: Color(0xFFF9FAFB),
            ),
            titleLarge: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Color(0xFFF9FAFB),
            ),
            titleMedium: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Color(0xFFF9FAFB),
            ),
            bodyLarge: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 16,
              color: Color(0xFFE5E7EB),
            ),
            bodyMedium: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 14,
              color: Color(0xFF9CA3AF),
            ),
            // WCAG AA (4.5:1) for 12 sp body text, which is the settings
            // subtitle stating the current value of every setting. The old
            // 0xFF6B7280 measured 4.34:1 on the pure-black scaffold and only
            // 3.65:1 on the 0xFF18181F dialog and bottom sheet; this is the
            // same slate lifted 15% and clears both (5.51:1 and 4.63:1).
            bodySmall: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 12,
              color: Color(0xFF7B8393),
            ),
            labelLarge: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.1,
              color: Color(0xFFF9FAFB),
            ),
          ),

      // AppBar
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF000000),
        elevation: 0,
        centerTitle: false,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),

      // Bottom Navigation
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: const Color(
          0xFF000000,
        ), // Pure Black matches background
        selectedItemColor: colorScheme.primary,
        unselectedItemColor: colorScheme.onSurfaceVariant,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        showSelectedLabels: false,
        showUnselectedLabels: false,
        landscapeLayout: BottomNavigationBarLandscapeLayout.spread,
      ),

      // Keep SnackBars visually consistent with the dark application instead
      // of Material's default inverse (light) surface.
      snackBarTheme: snackBarThemeFor(colorScheme),

      // Input Decoration
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF18181F), // Slightly lighter grey for fields
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colorScheme.primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 16,
        ),
      ),

      dividerColor: const Color(0xFF22222E),
      dividerTheme: const DividerThemeData(
        thickness: 1,
        space: 1,
        color: Color(0xFF22222E),
      ),

      // Switch Theme
      switchTheme: SwitchThemeData(
        thumbIcon: WidgetStateProperty.resolveWith<Icon?>((states) {
          if (states.contains(WidgetState.focused) ||
              states.contains(WidgetState.hovered)) {
            if (states.contains(WidgetState.selected)) {
              return const Icon(Icons.check_rounded, size: 14);
            } else {
              return const Icon(Icons.close_rounded, size: 14);
            }
          }
          return null;
        }),
      ),
    );
  }

  static ThemeData createLightTheme(ColorScheme? dynamicScheme) {
    _registerFontLicence();
    const colorScheme = ColorScheme.light(
      primary: lightCoral,
      onPrimary: Colors.white,
      primaryContainer: Color(0xFFFFDAD4),
      onPrimaryContainer: Color(0xFF410001),
      secondary: Color(0xFF775651),
      onSecondary: Colors.white,
      secondaryContainer: lightSurfaceHighlight,
      onSecondaryContainer: Color(0xFF2C1512),
      tertiary: lightCoral,
      onTertiary: Colors.white,
      tertiaryContainer: Color(0xFFFFDAD4),
      onTertiaryContainer: Color(0xFF410001),
      surface: lightBackground,
      onSurface: lightTextPrimary,
      onSurfaceVariant: lightTextSecondary,
      outline: Color(0xFFC9BBA6), // Warm sand outline
      outlineVariant: Color(0xFFD9C9AE), // Soft warm tan outlineVariant
      error: Color(0xFFBA1A1A),
      onError: Colors.white,
      surfaceContainerLowest: lightSurface,
      surfaceContainerLow: Color(0xFFF7F3EE),
      surfaceContainer: Color(0xFFEFEAE2),
      surfaceContainerHigh: lightSurfaceHighlight,
      surfaceContainerHighest: Color(0xFFE4D9C8),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: colorScheme.surface,

      // Dialog Theme
      dialogTheme: DialogThemeData(
        backgroundColor: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurface,
        ),
      ),

      // Bottom Sheet Theme
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: colorScheme.surface,
      ),

      // Card Theme
      cardTheme: CardThemeData(
        color: colorScheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        elevation: 1,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),

      // Material 3 Color Scheme
      colorScheme: colorScheme,

      // Typography
      textTheme: ThemeData.light().textTheme
          .apply(fontFamily: fontFamily)
          .copyWith(
            displayLarge: TextStyle(
              fontFamily: fontFamily,
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: colorScheme.onSurface,
            ),
            headlineMedium: TextStyle(
              fontFamily: fontFamily,
              fontSize: 24,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
            titleLarge: TextStyle(
              fontFamily: fontFamily,
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
            bodyLarge: TextStyle(
              fontFamily: fontFamily,
              fontSize: 16,
              color: colorScheme.onSurface,
            ),
            bodyMedium: TextStyle(
              fontFamily: fontFamily,
              fontSize: 14,
              color: colorScheme.onSurfaceVariant,
            ),
            // Full-strength onSurfaceVariant, not 80% of it: the alpha
            // blended 0xFF5C5C5C down to 0xFF7B7A79 on the 0xFFF5F1EC
            // scaffold, which is 3.81:1 and fails WCAG AA. Undimmed it is
            // 5.95:1 on the scaffold and 4.80:1 on the darkest container.
            bodySmall: TextStyle(
              fontFamily: fontFamily,
              fontSize: 12,
              color: colorScheme.onSurfaceVariant,
            ),
          ),

      // AppBar
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        elevation: 0,
        centerTitle: false,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: colorScheme.onSurface),
        titleTextStyle: TextStyle(
          color: colorScheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          fontFamily: fontFamily,
        ),
      ),

      // Bottom Navigation
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: colorScheme.surface,
        selectedItemColor: colorScheme.primary,
        unselectedItemColor: colorScheme.onSurfaceVariant,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
        showSelectedLabels: false,
        showUnselectedLabels: false,
      ),

      // Input Decoration
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),

      // Chip Theme
      chipTheme: ChipThemeData(
        backgroundColor: colorScheme.surfaceContainerHigh,
        disabledColor: colorScheme.onSurface.withValues(alpha: 0.12),
        selectedColor: colorScheme.primary.withValues(alpha: 0.15),
        secondarySelectedColor: colorScheme.primary.withValues(alpha: 0.15),
        labelStyle: TextStyle(color: colorScheme.onSurface),
        secondaryLabelStyle: TextStyle(color: colorScheme.primary),
        checkmarkColor: colorScheme.primary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide.none,
        ),
      ),

      // Switch Theme
      switchTheme: SwitchThemeData(
        thumbIcon: WidgetStateProperty.resolveWith<Icon?>((states) {
          if (states.contains(WidgetState.focused) ||
              states.contains(WidgetState.hovered)) {
            if (states.contains(WidgetState.selected)) {
              return const Icon(Icons.check_rounded, size: 14);
            } else {
              return const Icon(Icons.close_rounded, size: 14);
            }
          }
          return null;
        }),
      ),

      // Slider Theme
      sliderTheme: SliderThemeData(
        activeTrackColor: colorScheme.primary,
        inactiveTrackColor: colorScheme.primary.withValues(alpha: 0.24),
        thumbColor: colorScheme.primary,
        overlayColor: colorScheme.primary.withValues(alpha: 0.12),
      ),

      // Floating Action Button Theme
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
      ),

      // SnackBar Theme
      snackBarTheme: snackBarThemeFor(colorScheme),

      // Ripple / Splash / Highlights
      splashColor: colorScheme.primary.withValues(alpha: 0.1),
      hoverColor: colorScheme.primary.withValues(alpha: 0.04),
      highlightColor: colorScheme.primary.withValues(alpha: 0.05),

      // Selection Text Theme
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: colorScheme.primary,
        selectionColor: colorScheme.primary.withValues(alpha: 0.3),
        selectionHandleColor: colorScheme.primary,
      ),

      dividerColor: colorScheme.outlineVariant,
      dividerTheme: DividerThemeData(
        thickness: 1,
        space: 1,
        color: colorScheme.outlineVariant,
      ),
    );
  }
}
