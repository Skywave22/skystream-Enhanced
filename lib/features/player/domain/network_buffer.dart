/// Turning "how many minutes of video to hold" into the byte count libVLC
/// actually takes.
///
/// libVLC 3 has no read-ahead measured in time. `--prefetch-buffer-size` is
/// bytes, and the only time-based option is `--network-caching`, which is
/// output latency and is capped by libVLC at 60 s. So minutes have to be
/// converted, and a conversion needs a bitrate the buffer is sized before
/// anyone knows: the option goes on the libVLC instance, before a stream is
/// open. The rendition ceiling is the best guess available at that point.
///
/// mpv, which is where the minutes idea comes from, does the same thing in two
/// halves - `--demuxer-readahead-secs` for the wish and `--demuxer-max-bytes`
/// for the ceiling - and the ceiling is the half that matters, because three
/// minutes of 4K is over half a gigabyte of resident memory and an OOM kill on
/// anything but a desktop.
library;

import '../../../core/providers/device_info_provider.dart';

/// Nominal bitrate for a rendition height, in bits per second.
///
/// Deliberately generous rather than accurate. Undershooting buys less buffer
/// than asked for, which is a disappointment; overshooting reserves memory a
/// device may not have, which is a crash.
int nominalBitrateFor(int maxHeight) => switch (maxHeight) {
  >= 2160 => 25000000,
  >= 1440 => 16000000,
  >= 1080 => 8000000,
  >= 720 => 5000000,
  >= 480 => 2500000,
  _ => 1500000,
};

/// The most memory a device should ever hold in the read-ahead buffer.
///
/// The buffer is resident and never paged out, and it competes with the
/// decoder's own picture pool. A low-tier stick has a few hundred megabytes to
/// its name in total, so its ceiling is the one that stops this feature being
/// a crash rather than a setting.
int bufferCeilingBytesFor(DeviceTier tier) => switch (tier) {
  DeviceTier.low => 48 * 1024 * 1024,
  DeviceTier.standard => 128 * 1024 * 1024,
  DeviceTier.high => 256 * 1024 * 1024,
};

/// The `--prefetch-buffer-size` value, in KiB, for a wish of [minutes].
///
/// Clamped to [bufferCeilingBytesFor], so the answer is "as much of that wish
/// as this device can afford". Never zero: a buffer smaller than libVLC's own
/// 4 KiB floor is refused by the option's range.
int prefetchBufferKiBFor({
  required int minutes,
  required int maxHeight,
  required DeviceTier tier,
}) {
  final wanted = minutes * 60 * (nominalBitrateFor(maxHeight) ~/ 8);
  final allowed = wanted.clamp(4 * 1024, bufferCeilingBytesFor(tier));
  return allowed ~/ 1024;
}

/// What that wish actually costs, in whole megabytes, for showing beside the
/// setting. A viewer choosing "3 min" deserves to see it became 128 MB.
int prefetchBufferMbFor({
  required int minutes,
  required int maxHeight,
  required DeviceTier tier,
}) => prefetchBufferKiBFor(
  minutes: minutes,
  maxHeight: maxHeight,
  tier: tier,
) ~/ 1024;
