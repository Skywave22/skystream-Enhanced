import 'package:flutter/material.dart';

enum DeviceScreenType { mobile, tablet, desktop }

class ResponsiveBreakpoints {
  // Common standard breakpoints
  static const double tabletBreakpoint = 600;
  static const double desktopBreakpoint = 900;

  static DeviceScreenType getDeviceType(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;

    if (width >= desktopBreakpoint) {
      return DeviceScreenType.desktop;
    } else if (width >= tabletBreakpoint) {
      return DeviceScreenType.tablet;
    } else {
      return DeviceScreenType.mobile;
    }
  }

  static bool isMobile(BuildContext context) =>
      getDeviceType(context) == DeviceScreenType.mobile;

  static bool isTablet(BuildContext context) =>
      getDeviceType(context) == DeviceScreenType.tablet;

  static bool isDesktop(BuildContext context) =>
      getDeviceType(context) == DeviceScreenType.desktop;

  static bool isTabletOrLarger(BuildContext context) =>
      getDeviceType(context) != DeviceScreenType.mobile;
}

// Extension for easy access from BuildContext
extension ResponsiveContext on BuildContext {
  DeviceScreenType get deviceType => ResponsiveBreakpoints.getDeviceType(this);
  bool get isMobile => ResponsiveBreakpoints.isMobile(this);
  bool get isTablet => ResponsiveBreakpoints.isTablet(this);
  bool get isDesktop => ResponsiveBreakpoints.isDesktop(this);
  bool get isTabletOrLarger => ResponsiveBreakpoints.isTabletOrLarger(this);

  /// Whether this surface is being driven by directional focus movement - a
  /// remote, a D-pad, a gamepad stick - rather than by a pointer.
  ///
  /// This is an *input model*, declared by the host through
  /// [MediaQueryData.navigationMode], and it is the honest question a
  /// ten-foot layout wants to ask: "is a big screen being steered by a D-pad".
  /// It is deliberately **not** an answer to "is this a television".
  /// [DeviceProfile.isTv] - `android.software.leanback`, or an Apple TV
  /// `utsname` - is the single authority for that, because it is the only one
  /// of the two that reads a hardware fact rather than inferring one.
  ///
  /// What used to live here was a geometric guess -
  /// `Platform.isAndroid && aspectRatio > 1.0 && padding.top == 0` - and every
  /// call site OR-ed it with the real profile flag. An OR can only ever turn a
  /// non-TV into a TV; it can never rescue a real television, which already
  /// reports leanback. So the guess was pure downside, and it cost an Android
  /// phone held in landscape (or one on its way out of the player's
  /// `immersiveSticky` chrome, where the top inset is zero) its four gesture
  /// settings rows while the gestures themselves kept firing. Size decisions
  /// belong to the breakpoints above; device-class decisions belong to the
  /// device profile; neither of them is a guess made from insets.
  ///
  /// It is not a stand-in for "TV" either, and the `isTv` alias that used to
  /// sit below it is gone. Nothing in this app declares directional
  /// navigation - Flutter's default is [NavigationMode.traditional] and no
  /// widget here overrides it - so on a real Android TV this getter is
  /// *false*. Every ten-foot call site that leaned on it was leaning on a
  /// constant. Ask [DeviceProfile.isTv] for the device, a breakpoint above
  /// for the size, and this only if a host ever starts declaring the mode.
  bool get isDirectionalNavigation =>
      MediaQuery.maybeNavigationModeOf(this) == NavigationMode.directional;
}
