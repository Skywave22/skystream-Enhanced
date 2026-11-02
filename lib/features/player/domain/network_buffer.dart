/// How far ahead each video reads (spec 1.2): the buffer rule behind the
/// setting's Auto, the sizes the setting offers instead, and the split of a
/// torrent's cache.
///
/// Auto sizes by time, from the video's bitrate, capped by the device's
/// memory: a normal film holds about 100 MB, and a 20 GB 4K one what the cap
/// allows. A size the viewer picks is reserved exactly.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../../core/providers/device_info_provider.dart';
import '../../../core/providers/device_memory.dart';

/// The sizes offered, in megabytes.
///
/// Stops at 1024. The buffer is resident and competes with the decoder's own
/// picture pool, so past this the returns are small and the risk is not - but
/// it is offered, because a machine with memory to spare can spend it and
/// nothing here should decide that on the owner's behalf.
///
/// Note that the top of this range is not sized for the bottom of the device
/// range: a gigabyte is most of what a 2 GB handset has. Auto is what protects
/// a fresh install; this list is what someone who has gone looking for the
/// setting is allowed to ask for.
const List<int> kNetworkBufferChoicesMb = <int>[64, 128, 256, 512, 1024];

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

/// libVLC's own read-ahead floor: its ring is never smaller than
/// `prefetch-read-size`, 16 MiB, so asking for less does nothing. Torrents get
/// exactly this: TorrServer holds the film.
const int kRingFloorMb = 16;

/// The smallest torrent cache handed to TorrServer: its own default.
const int kTorrentCacheFloorMb = 64;

/// The smallest HLS/DASH buffer, in seconds: under this a slow patch empties
/// it.
const int kAdaptiveFloorSeconds = 20;

/// What kind of media a plan is for (spec 1.2's table).
enum BufferMedia {
  /// A file over HTTP: a CDN, a LAN server, a debrid link.
  httpFile,

  /// HLS or DASH on demand.
  adaptive,

  /// A live stream: TS, UDP, RTP, RTSP, or live HLS. libVLC's defaults.
  live,

  /// A torrent, through TorrServer.
  torrent,

  /// A file on this device, which libVLC doesn't read through its ring.
  local,
}

/// Where a plan's bitrate came from.
enum BitrateSource {
  /// The file's size over its runtime.
  sizeAndRuntime,

  /// A guess from its quality label.
  label,

  /// No label either: the 1080p guess.
  assumed,
}

/// How much one open reads ahead (spec 1.2): the answer of [bufferPlanFor].
///
/// Sizes are in MB of 1024 × 1024 bytes, the unit the buffer setting has
/// always used.
@immutable
class BufferPlan {
  const BufferPlan({
    required this.media,
    required this.capMb,
    required this.targetSeconds,
    required this.bitrateKbps,
    required this.bitrateFrom,
    this.ringMb,
    this.adaptiveSeconds,
    this.torrentCacheMb,
  });

  final BufferMedia media;

  /// libVLC's read-ahead for this media (`:prefetch-buffer-size`), or null
  /// for libVLC's own.
  final int? ringMb;

  /// The HLS/DASH buffer (`:adaptive-maxbuffer`), in seconds, or null.
  final int? adaptiveSeconds;

  /// TorrServer's cache for this stream, or null.
  final int? torrentCacheMb;

  /// The most this device should hold now.
  final int capMb;

  /// How far ahead the plan aims, in seconds.
  final int targetSeconds;

  /// The bitrate it sized from, and where that came from.
  final int bitrateKbps;
  final BitrateSource bitrateFrom;

  /// The QoE log's `buffer` event.
  Map<String, Object?> toJson() => <String, Object?>{
    'media': media.name,
    'ringMb': ringMb,
    'adaptiveSeconds': adaptiveSeconds,
    'torrentCacheMb': torrentCacheMb,
    'capMb': capMb,
    'targetSeconds': targetSeconds,
    'bitrateKbps': bitrateKbps,
    'bitrateFrom': bitrateFrom.name,
  };
}

/// The read-ahead for one open (spec 1.2).
///
/// - cap: the device's RAM ÷ 16, between 48 MB and 1 GB, halved when less
///   than four times that is free now ([bufferCapMb]);
/// - target: 60 s on a metered network, otherwise 180 s, or 360 s for a file
///   averaging 15 Mbit/s or more;
/// - bitrate: [estimateBitrateKbps].
///
/// A file gets target × bitrate, between 16 MiB and the cap; HLS and DASH get
/// the target, but no more than the cap holds at the guessed bitrate of the
/// highest height allowed ([maxHeight]), and no less than 20 s; a torrent gets
/// libVLC's 16 MiB ring and a TorrServer cache of target × bitrate rounded up
/// to a step of [kNetworkBufferChoicesMb], between 64 MB and the cap; live and
/// local media get nothing. [overrideMb], the viewer's own size, replaces the
/// rule: HLS gets it as seconds at its guess, a torrent as TorrServer's cache.
BufferPlan bufferPlanFor({
  required BufferMedia media,
  required DeviceMemory memory,
  required int fallbackRamMb,
  required bool metered,
  int? fileBytes,
  Duration? runtime,
  String label = '',
  int? height,
  int? maxHeight,
  int? overrideMb,
}) {
  final capMb = bufferCapMb(memory, fallbackRamMb: fallbackRamMb);
  final (kbps, from) = estimateBitrateKbps(
    fileBytes: fileBytes,
    runtime: runtime,
    label: label,
    height: height,
  );
  final targetSeconds = metered ? 60 : (kbps >= 15000 ? 360 : 180);
  final wantMb = _mbFor(targetSeconds, kbps);
  int? ringMb;
  int? adaptiveSeconds;
  int? torrentCacheMb;
  switch (media) {
    case BufferMedia.httpFile:
      ringMb = overrideMb ?? _within(wantMb, kRingFloorMb, capMb);
    case BufferMedia.torrent:
      // TorrServer holds the film; libVLC reads it through loopback.
      ringMb = kRingFloorMb;
      torrentCacheMb = overrideMb ?? _torrentStep(wantMb, capMb);
    case BufferMedia.adaptive:
      final topKbps = labelGuessKbps(height: maxHeight ?? 2160)!;
      final seconds = overrideMb != null
          ? _secondsIn(overrideMb, topKbps)
          : math.min(targetSeconds, _secondsIn(capMb, topKbps));
      adaptiveSeconds = math.max(kAdaptiveFloorSeconds, seconds);
    case BufferMedia.live:
    case BufferMedia.local:
      break;
  }
  return BufferPlan(
    media: media,
    capMb: capMb,
    targetSeconds: targetSeconds,
    bitrateKbps: kbps,
    bitrateFrom: from,
    ringMb: ringMb,
    adaptiveSeconds: adaptiveSeconds,
    torrentCacheMb: torrentCacheMb,
  );
}

/// The most read-ahead this device should hold now: its RAM ÷ 16, between
/// 48 MB and 1 GB, halved when less than four times that is free. A reading
/// with no total uses [fallbackRamMb]; one with no free figure counts as
/// enough free.
int bufferCapMb(DeviceMemory memory, {required int fallbackRamMb}) {
  final ram = memory.totalMb ?? fallbackRamMb;
  final cap = (ram ~/ 16).clamp(48, 1024);
  final free = memory.freeMb;
  return free != null && free < 4 * cap ? cap ~/ 2 : cap;
}

/// The RAM a tier's typical device has, for a reading that has none.
int tierRamMb(DeviceTier tier) => switch (tier) {
  DeviceTier.low => 1024,
  DeviceTier.standard => 4096,
  DeviceTier.high => 16384,
};

/// A file's average bitrate in kbit/s, and where it came from: its size over
/// its runtime when both are known and the answer is plausible (0.3 to 150
/// Mbit/s), otherwise a guess from its label or [height] ([labelGuessKbps]),
/// otherwise the 1080p guess.
///
/// The bounds catch a runtime that belongs to something else: an episode's
/// 24 minutes against a 40 GB season pack is 238 Mbit/s.
(int, BitrateSource) estimateBitrateKbps({
  int? fileBytes,
  Duration? runtime,
  String label = '',
  int? height,
}) {
  final seconds = runtime?.inSeconds ?? 0;
  if (fileBytes != null && fileBytes > 0 && seconds > 0) {
    final kbps = fileBytes * 8 ~/ seconds ~/ 1000;
    if (kbps >= 300 && kbps <= 150000) {
      return (kbps, BitrateSource.sizeAndRuntime);
    }
  }
  final guess = labelGuessKbps(label: label, height: height);
  return guess == null
      ? (8000, BitrateSource.assumed)
      : (guess, BitrateSource.label);
}

/// The spec's average-bitrate guesses, in kbit/s: 2160p, 4K or UHD 25 (60
/// with REMUX); 1080p 8 (30 with REMUX); 720p 4; anything lower 2. [height]
/// wins over the label's own; null when neither names a height.
int? labelGuessKbps({String label = '', int? height}) {
  final text = label.toLowerCase();
  final h = height != null && height > 0 ? height : _heightIn(text);
  if (h == null) return null;
  final remux = text.contains('remux');
  if (h >= 2160) return remux ? 60000 : 25000;
  if (h >= 1080) return remux ? 30000 : 8000;
  if (h >= 720) return 4000;
  return 2000;
}

final RegExp _uhd = RegExp(r'\b(4k|uhd|2160[pi]?)\b');
final RegExp _lines = RegExp(r'\b(\d{3,4})[pi]\b');

int? _heightIn(String text) {
  if (_uhd.hasMatch(text)) return 2160;
  final match = _lines.firstMatch(text);
  return match == null ? null : int.parse(match.group(1)!);
}

final RegExp _sizeLabel = RegExp(
  r'(\d+(?:[.,]\d+)?)\s*(gb|mb|gib|mib)\b',
  caseSensitive: false,
);

/// The size a label states ("2.4 GB", "850 MB"), in bytes, as Stremio rows
/// and many source names carry it. GB counts as GiB, as the add-on parser
/// counts it.
int? sizeFromLabel(String label) {
  final match = _sizeLabel.firstMatch(label);
  if (match == null) return null;
  final value = double.tryParse(match.group(1)!.replaceAll(',', '.'));
  if (value == null || value <= 0) return null;
  final giga = match.group(2)!.toLowerCase().startsWith('g');
  return (value * (giga ? 1 << 30 : 1 << 20)).round();
}

/// The runtime to divide a file's size by, in the spec's order: the length
/// measured on an earlier play, the episode's runtime, the item's duration,
/// TMDB's runtime. Zero or less is unknown.
Duration? runtimeFor({
  Duration? measured,
  int? episodeMinutes,
  int? itemMinutes,
  int? tmdbMinutes,
}) {
  if (measured != null && measured > Duration.zero) return measured;
  for (final minutes in [episodeMinutes, itemMinutes, tmdbMinutes]) {
    if (minutes != null && minutes > 0) return Duration(minutes: minutes);
  }
  return null;
}

int _mbFor(int seconds, int kbps) =>
    (seconds * kbps * 1000 / 8 / (1 << 20)).ceil();

int _secondsIn(int mb, int kbps) => mb * (1 << 20) * 8 ~/ (kbps * 1000);

int _within(int mb, int floor, int cap) =>
    mb.clamp(floor, math.max(floor, cap));

/// A torrent cache on one of [kNetworkBufferChoicesMb]: the smallest that
/// holds [mb], within the cap. TorrServer's write costs over two seconds and
/// drops every torrent, so it runs only when a value differs from the one the
/// server holds - and values on steps repeat.
int _torrentStep(int mb, int cap) => _within(
  kNetworkBufferChoicesMb.firstWhere(
    (choice) => choice >= mb,
    orElse: () => kNetworkBufferChoicesMb.last,
  ),
  kTorrentCacheFloorMb,
  cap,
);
