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
/// Stops at 1024. The buffer is resident and competes with the decoder's own
/// picture pool, so past this the returns are small and the risk is not - but
/// it is offered, because a machine with memory to spare can spend it and
/// nothing here should decide that on the owner's behalf.
///
/// Note that the top of this range is not sized for the bottom of the device
/// range: a gigabyte is most of what a 2 GB handset has. The tier defaults
/// below are what protect a fresh install; this list is what someone who has
/// gone looking for the setting is allowed to ask for.
const List<int> kNetworkBufferChoicesMb = <int>[64, 128, 256, 512, 1024];

/// Where a device starts before anyone chooses.
///
/// Scaled by tier rather than by a raw megabyte count because the tier already
/// folds in Android's own low-RAM flag, which an OEM sets knowing things about
/// the device that a number does not capture.
int defaultNetworkBufferMb(DeviceTier tier) => switch (tier) {
  // Cheap sticks and old phones. 128 MB is still eight times libVLC's own
  // 16 MiB default and leaves the decoder room to work.
  DeviceTier.low => 128,

  // Ordinary phones, tablets and TV boxes.
  DeviceTier.standard => 256,

  // Anything with memory to spare. Every desktop is here by definition, and
  // so is any handset or tablet reporting 6 GB or more - the tier is a RAM
  // verdict, not a platform one, so a modern phone gets the same 512 MB a
  // laptop does.
  DeviceTier.high => 512,
};

/// The buffer to actually use: what the viewer chose, or this device's default
/// when they have not chosen.
int resolveNetworkBufferMb(int? chosen, DeviceTier tier) =>
    chosen ?? defaultNetworkBufferMb(tier);

/// The most of a torrent cache worth spending on data already played.
///
/// A cap, because the behind-window is dead weight for anyone who never seeks
/// backwards, and the ahead-window is what keeps a torrent playing at all.
/// 64 MB is roughly a minute of 1080p, which is as far back as a viewer
/// realistically scrubs by hand.
const int kMaxTorrentBehindMb = 64;

/// The share of a torrent cache kept *ahead* of the read point, as the
/// percentage TorrServer's `readerReadAHead` wants.
///
/// TorrServer splits one cache between read-ahead and history, and the split
/// is the only backward-buffer control anywhere in this player: libVLC 3's
/// prefetch filter takes a size and decides the rest itself. So this is where
/// "a ten second step back should not re-download" is actually answered.
///
/// A quarter of the cache, capped by [kMaxTorrentBehindMb]. At the 95 % this
/// replaces, a 64 MB cache kept about 3 MB behind the playhead - under four
/// seconds of 1080p, so every back-step of any size re-fetched pieces the
/// reader had just finished with.
///
/// Returns a percentage rather than a size because that is TorrServer's unit,
/// and it is rounded, so the arithmetic is worth a test rather than a comment.
int torrentReadAheadPercent(int cacheMb) {
  if (cacheMb <= 0) return 95;
  final behind = (cacheMb * 0.25).round().clamp(0, kMaxTorrentBehindMb);
  final ahead = ((cacheMb - behind) / cacheMb * 100).round();
  // Never so little read-ahead that the torrent cannot keep up; the behind
  // window is a convenience and the ahead window is the playback.
  return ahead.clamp(60, 99);
}
