/// How large a read-ahead buffer to start a device with.
///
/// A default, never a cap. An earlier version of this converted a duration
/// into bytes and then clamped the result to what the device could hold, which
/// meant most of the choices on offer produced the same buffer and the control
/// mostly did nothing. The number a viewer picks is now reserved exactly; this
/// only decides where a fresh install starts.
library;

import '../../../core/providers/device_info_provider.dart';

/// The sizes offered, in megabytes.
///
/// Stops at 512. The buffer is resident and competes with the decoder's own
/// picture pool, so past this the returns are small and the risk is not - but
/// it is offered, because a desktop with plenty of memory can spend it and
/// nothing here should decide that on the owner's behalf.
const List<int> kNetworkBufferChoicesMb = <int>[32, 64, 128, 256, 512];

/// Where a device starts before anyone chooses.
///
/// Scaled by tier rather than by a raw megabyte count because the tier already
/// folds in Android's own low-RAM flag, which an OEM sets knowing things about
/// the device that a number does not capture.
int defaultNetworkBufferMb(DeviceTier tier) => switch (tier) {
  // Cheap sticks and old phones. 64 MB is still four times libVLC's own
  // default and leaves the decoder room to work.
  DeviceTier.low => 64,

  // Ordinary phones, tablets and TV boxes.
  DeviceTier.standard => 128,

  // Desktops and anything with memory to spare.
  DeviceTier.high => 256,
};

/// The buffer to actually use: what the viewer chose, or this device's default
/// when they have not chosen.
int resolveNetworkBufferMb(int? chosen, DeviceTier tier) =>
    chosen ?? defaultNetworkBufferMb(tier);
