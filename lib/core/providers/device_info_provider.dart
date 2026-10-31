import 'dart:ui' as ui;
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'device_memory.dart';

part 'device_info_provider.g.dart';

/// How much work this device can reasonably be asked to do.
///
/// Kept deliberately coarse — three buckets, not a score. Callers should branch
/// on this rather than re-deriving their own idea of "weak device" from
/// [DeviceProfile.isTv], which conflates form factor with capability: a Shield
/// and a 1 GB stick are both TVs.
enum DeviceTier {
  /// Cheap sticks and old phones. Android's own low-RAM flag, or under ~2 GB.
  low,

  /// Ordinary phones, tablets and TV boxes.
  standard,

  /// Desktops and anything with plenty of memory.
  high,
}

class DeviceProfile {
  final bool isTv;
  final bool isTablet;

  /// Indicates if running on a desktop operating system (macOS, Windows, Linux)
  /// Use this for capability checks (e.g. window controls, mouse hovers),
  /// NOT for layout sizing. Use [ResponsiveBreakpoints] for layout sizing.
  final bool isDesktopOS;

  /// Total physical RAM in megabytes, or null where the platform does not
  /// report it (desktop). Null is not "small" — check [tier] instead.
  final int? physicalRamMb;

  /// Coarse capability bucket. See [DeviceTier].
  final DeviceTier tier;

  /// Whether the OS turns the screen when the app asks: see
  /// [obeysOrientationRequests]. Meaningless on a television or a desktop.
  final bool obeysOrientationRequests;

  const DeviceProfile({
    this.isTv = false,
    this.isTablet = false,
    this.isDesktopOS = false,
    this.physicalRamMb,
    this.tier = DeviceTier.standard,
    this.obeysOrientationRequests = true,
  });

  bool get isLargeScreen => isTv || isTablet || isDesktopOS;

  /// Convenience for the common "be careful here" check.
  bool get isLowEnd => tier == DeviceTier.low;
}

/// Whether a handset or tablet turns its screen when an app asks.
///
/// iPadOS 26.5 and 27 refuse in both windowing modes, and Android 16 (API 36)
/// ignores the request on a screen 600 dp wide or more for an app that targets
/// it, as this one does. Measured on 2026-10-11: the iPad Pro 11-inch (M5)
/// simulator and the API 36 emulator at 1600x2560 and 320 dpi stayed put,
/// while the API 35 tablet emulator and both phones turned.
@visibleForTesting
bool obeysOrientationRequests({
  required bool isIOS,
  required bool isTablet,
  int? androidSdk,
}) => !isTablet || (!isIOS && (androidSdk ?? 0) < 36);

@riverpod
Future<DeviceProfile> deviceProfile(Ref ref) async {
  bool isTv = false;
  bool isTablet = false;
  bool isDesktopOS = false;
  int? physicalRamMb;
  var tier = DeviceTier.standard;
  var obeysOrientation = true;

  if (!kIsWeb) {
    if (Platform.isAndroid || Platform.isIOS) {
      final view = ui.PlatformDispatcher.instance.views.first;
      final size = view.physicalSize / view.devicePixelRatio;
      if (size.shortestSide >= 600) {
        isTablet = true;
      }
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        // Two signals, because one of them misses. Certified Android TV
        // devices must declare leanback, but an uncertified AOSP box on a
        // television declares only the older television feature - and such a
        // box lands as a *phone*, not a tablet, because a 1080p panel at TV
        // density measures 960x540dp and 540 is under the tablet threshold
        // above. A phone verdict is what lets the player pin an orientation on
        // something that cannot rotate.
        isTv = androidInfo.systemFeatures.contains('android.software.leanback') ||
            androidInfo.systemFeatures.contains('android.hardware.type.television');
        physicalRamMb = androidInfo.physicalRamSize;
        // The OEM's low-RAM verdict, through the app's memory channel: see
        // [androidTier].
        final memory = await readDeviceMemory();
        tier = androidTier(
          lowRam: memory.lowRam,
          physicalRamMb: androidInfo.physicalRamSize,
        );
        obeysOrientation = obeysOrientationRequests(
          isIOS: false,
          isTablet: isTablet,
          androidSdk: androidInfo.version.sdkInt,
        );
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        isTv = iosInfo.utsname.machine.startsWith('AppleTV') || iosInfo.model == 'Apple TV';
        physicalRamMb = iosInfo.physicalRamSize;
        tier = _tierFromRam(iosInfo.physicalRamSize);
        obeysOrientation = obeysOrientationRequests(
          isIOS: true,
          isTablet: isTablet,
        );
      }
    }

    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      isDesktopOS = true;
      // A desktop's tier follows its actual RAM: a 4 GB laptop is not the same
      // as a 32 GB workstation. Read memory the same way Android does so a
      // constrained desktop gets the smaller caches instead of `high`.
      final memory = await readDeviceMemory();
      physicalRamMb = memory.totalMb;
      tier = _tierFromRam(memory.totalMb ?? 0);
    }
  }

  return DeviceProfile(
    isTv: isTv,
    isTablet: isTablet,
    isDesktopOS: isDesktopOS,
    physicalRamMb: physicalRamMb,
    tier: tier,
    obeysOrientationRequests: obeysOrientation,
  );
}

/// An Android device's tier: low when the OEM says it is a low-RAM device
/// (`ActivityManager.isLowRamDevice()`, read through [readDeviceMemory]),
/// otherwise by its RAM. device_info_plus's own `isLowRamDevice` is
/// `MemoryInfo.lowMemory`, which says only that memory is short right now.
@visibleForTesting
DeviceTier androidTier({required bool lowRam, required int physicalRamMb}) =>
    lowRam ? DeviceTier.low : _tierFromRam(physicalRamMb);

/// Buckets raw megabytes. Thresholds are deliberately generous: the cost of
/// treating a capable device as low-end is a slightly smaller buffer, while the
/// cost of the reverse is the stutter and thermal behaviour this exists to avoid.
DeviceTier _tierFromRam(int mb) {
  if (mb <= 0) return DeviceTier.standard; // unreported — do not guess
  if (mb < 2048) return DeviceTier.low;
  if (mb >= 6144) return DeviceTier.high;
  return DeviceTier.standard;
}
