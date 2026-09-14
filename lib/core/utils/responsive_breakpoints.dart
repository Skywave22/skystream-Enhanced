import 'package:flutter/material.dart';

enum DeviceScreenType { mobile, tablet, desktop }

class ResponsiveBreakpoints {
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

extension ResponsiveContext on BuildContext {
  DeviceScreenType get deviceType => ResponsiveBreakpoints.getDeviceType(this);
  bool get isMobile => ResponsiveBreakpoints.isMobile(this);
  bool get isTablet => ResponsiveBreakpoints.isTablet(this);
  bool get isDesktop => ResponsiveBreakpoints.isDesktop(this);
  bool get isTabletOrLarger => ResponsiveBreakpoints.isTabletOrLarger(this);

  /// Whether this surface is being driven by directional focus movement - a
  /// remote, a D-pad, a gamepad stick - rather than by a pointer.
  ///
  /// This is an input model declared by the host through
  /// [MediaQueryData.navigationMode], not a device class: [DeviceProfile.isTv]
  /// is the single authority for "is this a television". Nothing in this app
  /// declares directional navigation and Flutter's default is
  /// [NavigationMode.traditional], so on a real Android TV this getter is
  /// false. Ask [DeviceProfile.isTv] for the device and a breakpoint above for
  /// the size.
  bool get isDirectionalNavigation =>
      MediaQuery.maybeNavigationModeOf(this) == NavigationMode.directional;
}
