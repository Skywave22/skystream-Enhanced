/// The decisions the player makes when playback is not, or may not be, healthy.
///
/// All are pure, and all live here rather than in the screen, because the
/// screen owns a native surface that no test can drive.
library;

import 'package:flutter/foundation.dart' show TargetPlatform;

import '../../../core/providers/device_info_provider.dart';

/// What to do about a picture that has stopped moving.
enum StallAction {
  /// Nothing yet. Either playback is fine or the stall is too young to act on.
  none,

  /// Re-issue the current position and resume, which forces a demuxer that
  /// dropped its request to start a new one.
  nudge,

  /// Hand the source to the failover ladder, which decides between reopening
  /// it and moving on.
  recover,
}

/// How long a source that has produced frames may sit at one position before
/// the engine gets a kick.
///
/// Long enough that an ordinary rebuffer on a slow connection rides it out: a
/// nudge forces a fresh request, which on a stream that is merely refilling
/// its buffer costs more than it saves.
const Duration kStallNudgeAfter = Duration(seconds: 10);

/// How long any source may make no progress at all before it is abandoned.
const Duration kStallRecoverAfter = Duration(seconds: 25);

/// A torrent's first frame waits on pieces arriving, not on a socket, and on a
/// cold magnet that is measured in minutes. The ordinary deadline would
/// abandon every torrent before it had a chance to seed.
const Duration kTorrentStallRecoverAfter = Duration(minutes: 3);

/// Whether a stall of [stalledFor] warrants doing something about it yet.
///
/// The input is elapsed-time-since-progress rather than the engine's state
/// enum: libVLC reports `buffering` throughout healthy playback on some
/// builds, so a watchdog driven by the enum fires constantly. An advancing
/// position is the only trustworthy sign of playback.
///
/// [lastAction] is the highest rung already fired for this stall window, so
/// each rung fires once; the caller clears it the moment the position moves.
/// The rungs are tested in descending severity, so a freeze noticed late — a
/// suspended laptop that missed a minute of ticks — escalates straight to
/// recovery instead of walking the ladder a second at a time.
StallAction stallActionFor({
  required Duration stalledFor,
  required bool hadFrames,
  required StallAction lastAction,
  Duration recoverAfter = kStallRecoverAfter,
}) {
  if (stalledFor >= recoverAfter && lastAction != StallAction.recover) {
    return StallAction.recover;
  }
  // Nothing has been decoded yet, so there is no position to seek back to and
  // no demuxer to unstick. Waiting out the deadline is the only move.
  if (!hadFrames) return StallAction.none;
  if (stalledFor >= kStallNudgeAfter && lastAction == StallAction.none) {
    return StallAction.nudge;
  }
  return StallAction.none;
}

/// The next candidate to open after [from], or null once every one has had a
/// turn.
///
/// Walks the ring rather than counting upwards: the first source opened is
/// whichever the resolver picked, routinely not zero, so counting upwards
/// leaves every candidate before it permanently unreachable by failover.
///
/// [tried] is what stops the ring becoming a loop. It is a *walk's* memory,
/// not the session's — a source that plays for an hour before the network
/// drops has earned a fresh walk.
int? nextFailoverIndex({
  required int from,
  required int total,
  required Set<int> tried,
}) {
  if (total <= 0) return null;
  for (var step = 1; step <= total; step++) {
    final candidate = (from + step) % total;
    if (!tried.contains(candidate)) return candidate;
  }
  return null;
}

/// What the decoder is doing behind a clock that *is* advancing.
///
/// The stall watchdog above only speaks when the position has frozen, so the
/// two can never fire for the same tick. Audio drives libVLC's clock, so a
/// picture that never arrives, or arrives at two frames a second, leaves the
/// position advancing perfectly and every other recovery path silent.
enum VideoHealth {
  /// A picture is reaching the screen, or there is not yet enough evidence to
  /// say otherwise.
  ok,

  /// The clock advanced across a whole window and not one picture was
  /// displayed: either the video output never opened or the decoder produced
  /// nothing. The viewer is looking at a black rectangle with sound.
  absent,

  /// Pictures reach the screen, but most of what is decoded is thrown away
  /// for arriving late — a slideshow with perfect audio, which is what
  /// software-decoding a rendition the SoC has no hardware profile for does.
  overwhelmed,
}

/// How long a window of playback must cover before [videoHealthFor] will
/// convict on it.
///
/// Long enough that the ragged first seconds after an open are not sampled at
/// all: the caller takes its baseline reading when the window opens, so the
/// counters this sees are the window's own.
const Duration kVideoHealthWindow = Duration(seconds: 8);

/// The share of pictures a decoder may throw away before it is judged unable
/// to keep up.
///
/// A tenth is ordinary on a busy device and invisible. A third is not
/// recoverable by waiting: with `--drop-late-frames` on (libVLC's default) it
/// means the decoder is running behind the clock and is being helped to catch
/// up by discarding work.
const double kLostPictureShare = 0.3;

/// How many pictures a window must account for before its ratio means
/// anything. Eight seconds of ordinary playback is ~200, so only a window that
/// saw almost nothing falls under this, and that case is already caught by
/// [VideoHealth.absent].
const int kMinPictureSample = 50;

/// Reads one window of decoder counters.
///
/// [displayed] and [lost] are the pictures shown and thrown away *over this
/// window*, not since the media opened: the caller subtracts a baseline taken
/// when the window opened. Deltas rather than totals, so a bad first ten
/// seconds cannot convict a session that recovered and a vout that dies an
/// hour in is caught as readily as one that never opened.
///
/// [statsAvailable] is libVLC's own admission that it has numbers to give. A
/// backend that reports nothing must never be convicted on its zeroes.
///
/// [hasVideoTrack] keeps an audio-only source out of the verdict entirely: it
/// has no picture to miss.
VideoHealth videoHealthFor({
  required bool statsAvailable,
  required bool hasVideoTrack,
  required Duration measuredFor,
  required int displayed,
  required int lost,
}) {
  if (!statsAvailable || !hasVideoTrack) return VideoHealth.ok;
  if (measuredFor < kVideoHealthWindow) return VideoHealth.ok;
  if (displayed <= 0) return VideoHealth.absent;
  final total = displayed + lost;
  if (total >= kMinPictureSample && lost / total >= kLostPictureShare) {
    return VideoHealth.overwhelmed;
  }
  return VideoHealth.ok;
}

/// The rendition heights an adaptive ladder is actually built around.
///
/// Ascending, and the only values [adaptiveMaxHeightFor] and [stepDownFrom]
/// will ever produce: `--adaptive-maxheight` honours a cap literally, so 963
/// would exclude the 1080p rung it was meant to select.
const List<int> kRenditionRungs = <int>[720, 1080, 1440, 2160];

/// The lowest rung the app will ever ask for.
///
/// A device that cannot manage 720p will not be rescued by 480p, and every
/// device that can show anything at all can show this.
const int kMinRenditionHeight = 720;

/// The tallest rendition a device that is not known to be capable may pick.
///
/// 4K is the whole of the problem this cap exists for: an HEVC Main10@L5.1
/// profile that older silicon has no hardware path for, and four times the
/// bandwidth for a picture the panel usually cannot show. It is a ceiling and
/// not a floor — libVLC still climbs the ladder freely underneath it.
const int kConservativeRenditionHeight = 1080;

/// Whether the decoder this platform will use is a hardware one.
///
/// [preference] is the user's `--avcodec-hw` setting, and it only decides
/// anything where it reaches a decoder. Android is that platform. Darwin
/// decodes on VideoToolbox, a standalone module in VLC 3 that `avcodec-hw`
/// has no authority over, so the hardware path is there whichever way the
/// switch is set; Windows and Linux render through the vmem callbacks, which
/// pin `avcodec-hw` to none, and have no hardware decoder outside avcodec, so
/// they are software either way. See `VlcDecodingConfig.hardwareAcceleration`.
///
/// Exhaustive on purpose: a platform this app grows a player for has to be
/// placed here before it compiles.
bool hardwareDecodeAvailable({
  required TargetPlatform platform,
  required bool preference,
}) => switch (platform) {
  TargetPlatform.android => preference,
  TargetPlatform.iOS || TargetPlatform.macOS => true,
  TargetPlatform.windows ||
  TargetPlatform.linux ||
  TargetPlatform.fuchsia => false,
};

/// The cap to put on `--adaptive-maxheight` for this device.
///
/// [panelHeightPx] is the shorter side of the surface the video will be shown
/// on, in physical pixels — 1080 on any 1080p television, whatever its
/// reported density. Pass 0 where the surface can be resized mid-playback (a
/// desktop window) or is not known; the cap then rests on the tier alone.
///
/// [tier] is a heuristic and cannot be anything else: nothing Flutter can
/// reach tells us which MediaCodec profiles the SoC implements, and the
/// failure guarded against — no hardware path for 4K HEVC, so avcodec takes
/// it at three frames a second — is exactly a codec-profile question. RAM is
/// the proxy available, so [DeviceTier.high] (6 GB or a desktop) is the only
/// class handed the top rungs and everything else, including an unknown
/// device, gets
/// [kConservativeRenditionHeight].
///
/// [hardwareDecode] is what the silicon will actually do — see
/// [hardwareDecodeAvailable] — and not the user's preference, which is the
/// same question on Android alone. False means every rendition is decoded on
/// the CPU, so no device is in the capable class any more and the weakest
/// ones drop a rung further.
int adaptiveMaxHeightFor({
  required DeviceTier tier,
  required int panelHeightPx,
  required bool hardwareDecode,
}) {
  var cap = switch (tier) {
    DeviceTier.high => kRenditionRungs.last,
    // The same number for both on purpose: these tiers differ in how much
    // they can hold, not in which codec profiles their silicon implements,
    // and 4K is the only rung that turns on the latter.
    DeviceTier.standard || DeviceTier.low => kConservativeRenditionHeight,
  };
  if (!hardwareDecode) {
    // Software decode on a device already short of memory is the one
    // combination that cannot manage 1080p either.
    final softwareCap = tier == DeviceTier.low
        ? kMinRenditionHeight
        : kConservativeRenditionHeight;
    if (softwareCap < cap) cap = softwareCap;
  }
  final panelCap = renditionRungFor(panelHeightPx);
  if (panelCap != null && panelCap < cap) cap = panelCap;
  return cap < kMinRenditionHeight ? kMinRenditionHeight : cap;
}

/// The shortest rung that still covers [heightPx], or null when there is no
/// measurement to go on.
///
/// Rounds *up*: a 900-line panel is served by the 1080p rung, because the
/// alternative is asking for a picture smaller than the screen and upscaling
/// it.
int? renditionRungFor(int heightPx) {
  if (heightPx <= 0) return null;
  for (final rung in kRenditionRungs) {
    if (rung >= heightPx) return rung;
  }
  return kRenditionRungs.last;
}

/// One rung down from [cap], or null when [cap] is already the floor.
///
/// Null is the caller's signal to stop trying: a device dropping frames at
/// [kMinRenditionHeight] will not be rescued by asking for less, and a
/// step-down loop with no bottom would reopen the media forever.
int? stepDownFrom(int cap) {
  int? below;
  for (final rung in kRenditionRungs) {
    if (rung < cap) below = rung;
  }
  if (below == null || below < kMinRenditionHeight) return null;
  return below;
}
