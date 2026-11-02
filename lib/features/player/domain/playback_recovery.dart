/// The decisions the player makes when playback is not, or may not be, healthy.
///
/// All are pure, and all live here rather than in the screen, because the
/// screen owns a native surface that no test can drive.
library;

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:vlc_player/vlc_player.dart'
    show VlcAudioInterruption, VlcMediaStats, VlcPlaybackState;

import '../../../core/providers/device_info_provider.dart';
import 'stream_resolver.dart' show ProbeOutcome;

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
/// its buffer costs more than it saves. A stream seen to be refilling - bytes
/// still arriving - is not nudged at all; see [stallActionFor].
const Duration kStallNudgeAfter = Duration(seconds: 10);

/// How long any source may make no progress at all before it is abandoned.
const Duration kStallRecoverAfter = Duration(seconds: 25);

/// [kStallNudgeAfter] for a stall that began with a seek.
///
/// A seek that lands outside libVLC's read-ahead fetches its keyframe run-up
/// and three seconds of buffer before the picture moves, which at 4K remux
/// bitrates on an ordinary line takes longer than [kStallNudgeAfter]. Nor do
/// the byte counters say it is under way: libVLC updates them from its input
/// thread, and that thread is the one waiting on the read. Measured on the TV
/// emulator, they stood still for the first ten seconds of a refill that was
/// arriving the whole time.
const Duration kStallNudgeAfterSeek = Duration(seconds: 20);

/// [kStallRecoverAfter] for a stall that began with a seek. See
/// [kStallNudgeAfterSeek].
const Duration kStallRecoverAfterSeek = Duration(seconds: 40);

/// How long a source still delivering bytes may sit at one position before
/// it is abandoned anyway.
///
/// Room for the slowest refill worth waiting for - a 4K remux's keyframe
/// run-up and buffer after a seek, on a line barely faster than its bitrate -
/// and no more: a source trickling bytes it can never play at is as good as
/// dead, and the failover ladder has others to try.
const Duration kStallRecoverWhileArrivingAfter = Duration(seconds: 60);

/// How long a source may go, from the moment it starts opening, without a
/// sign of progress before it is given up on: see [FirstFrameWatch].
///
/// Counted by the attempt's own watch rather than by the stall watchdog: the
/// watchdog stands down while the engine reports paused, stopped or ended, and
/// before the screen reaches its playing stage, and a source stuck in any of
/// those said "Opening…" for minutes.
const Duration kFirstFrameDeadline = Duration(seconds: 30);

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
///
/// [arriving] is whether the source has delivered bytes in the last few
/// seconds. A frozen picture over a source that is still delivering is a
/// refill, not a source gone quiet: a seek that has to fetch its keyframe
/// run-up and a fresh buffer outlasts [kStallNudgeAfter] on an ordinary line
/// at 4K remux bitrates. It gets no nudge, whose fresh request would throw
/// the refill away and start it over, and [kStallRecoverWhileArrivingAfter]
/// before it is given up on.
///
/// [afterSeek] is whether the stall began with a seek, which gets
/// [kStallNudgeAfterSeek] and [kStallRecoverAfterSeek] for its refill.
///
/// [adaptive] is HLS or DASH, which never get the nudge. Its seek to the
/// frozen place makes libVLC restart every stream at the playhead's segment,
/// throwing away the read-ahead: 4.6-5.0 MB per stall in every Part 1 and
/// Part 2 run, on every platform. Predictive then chooses a rendition from
/// the emptied buffer, a rung lower, and the seek lands up to a segment early
/// (SkyStream's research, 2026-10-15). A stall that ends needs nothing:
/// libVLC's own download carries on when the data does.
StallAction stallActionFor({
  required Duration stalledFor,
  required bool hadFrames,
  required StallAction lastAction,
  Duration recoverAfter = kStallRecoverAfter,
  bool arriving = false,
  bool afterSeek = false,
  bool adaptive = false,
}) {
  var giveUpAfter = recoverAfter;
  if (afterSeek && giveUpAfter < kStallRecoverAfterSeek) {
    giveUpAfter = kStallRecoverAfterSeek;
  }
  if (arriving && giveUpAfter < kStallRecoverWhileArrivingAfter) {
    giveUpAfter = kStallRecoverWhileArrivingAfter;
  }
  if (stalledFor >= giveUpAfter && lastAction != StallAction.recover) {
    return StallAction.recover;
  }
  // Nothing has been decoded yet, so there is no position to seek back to and
  // no demuxer to unstick. Waiting out the deadline is the only move.
  if (!hadFrames) return StallAction.none;
  if (arriving || adaptive) return StallAction.none;
  final nudgeAfter = afterSeek ? kStallNudgeAfterSeek : kStallNudgeAfter;
  if (stalledFor >= nudgeAfter && lastAction == StallAction.none) {
    return StallAction.nudge;
  }
  return StallAction.none;
}

/// The stall watchdog's clock (spec 2, *Detection*): how long, on the wall
/// clock, the position has stood still.
///
/// A minute the device slept counts as a minute, so a connection that died
/// while a laptop slept is caught the moment it wakes. A clock set back counts
/// as nothing. And a jump over playback that moved counts as nothing either: a
/// position that changed since the last tick starts the count again, however
/// much time the clock says passed. An NTP correction or a television leaving
/// standby with playback running is not a stall.
class StallClock {
  DateTime? _lastTick;
  Duration? _position;
  Duration _stalledFor = Duration.zero;

  Duration get stalledFor => _stalledFor;

  /// One watchdog tick, with the position playback is at. True when it moved
  /// since the last tick.
  bool tick(Duration position) {
    final now = clock.now();
    final last = _lastTick;
    _lastTick = now;
    final moved = _position != null && position != _position;
    _position = position;
    if (moved) {
      _stalledFor = Duration.zero;
      return true;
    }
    if (last == null) return false;
    final elapsed = now.difference(last);
    if (elapsed > Duration.zero) _stalledFor += elapsed;
    return false;
  }

  /// Starts the count again from now: the position moved between ticks, a
  /// seek was asked for, or playback stopped being expected. The time before
  /// it is nobody's stall: ten minutes paused is not ten minutes stalled the
  /// moment play resumes.
  void restart() {
    _lastTick = clock.now();
    _stalledFor = Duration.zero;
  }

  /// Forgets everything, for a new attempt.
  void reset() {
    _lastTick = null;
    _position = null;
    _stalledFor = Duration.zero;
  }
}

/// The byte count that says a source is still delivering: the demuxer's for
/// HLS and DASH, whose segments libVLC's adaptive module downloads itself
/// while the input's access reads only the master playlist (`access.c`, 3.0.24),
/// and the access's for everything else.
int arrivalBytesOf(VlcMediaStats stats, {required bool adaptive}) =>
    adaptive ? stats.demuxReadBytes : stats.readBytes;

/// How far the clock may run past the last picture decoded before a video is
/// starved.
const Duration kVideoStarvedAfter = Duration(seconds: 3);

/// How close to the end a frozen picture is left alone: a video track may
/// stop a moment before the audio does.
const Duration kStarvedNearEnd = Duration(seconds: 5);

/// The slowest a video's pictures may have been coming, in pictures per second
/// of playback, for a gap in them to be starving. A slideshow, or a still
/// image over a radio stream, changes picture less often than
/// [kVideoStarvedAfter] and is fed for all that.
const double kStarvedMinPictureRate = 2;

/// How much playback the pictures' rate is read across: long enough that the
/// trickle a starving video's last pictures come at is a small part of it.
const Duration kStarvedRateWindow = Duration(seconds: 5);

/// Watches for a picture frozen while the sound plays on (plan note 5).
///
/// libVLC 3 downloads an HLS or DASH stream's video and audio apart, and a
/// stream ends for good when one segment download fails (`Streams.cpp`,
/// 3.0.24). In every Part 1 and Part 2 drop20-hls run on macOS, iOS, Windows
/// and Linux, the picture froze 10-16 s after the cut while 84-108 s of
/// buffered audio carried the clock on. Neither the stall watchdog nor
/// [videoHealthFor] can see it: the position moves, and libVLC re-displays
/// its last picture every 80 ms and counts each one as displayed. Decoded
/// pictures can't lie: the decoder had nothing new to decode.
///
/// For media with a video track, on adaptive media only. A file's video and
/// audio come from one read, so one can't starve alone.
class StarvedVideoWatch {
  int? _decoded;
  Duration? _pictureAt;
  Duration? _lastPosition;

  /// Where new pictures came, over the last [kStarvedRateWindow] of playback.
  final _recent = <({Duration position, int decoded})>[];

  /// The rate the pictures came at across the last [kStarvedRateWindow] of
  /// playback. Not across the last gap between new ones: a starving video's
  /// last pictures trickle in, and on macOS its last 2 came over a second of
  /// sound, which read as a slideshow and was never convicted (P1 Part 3).
  double? _rate;

  /// One sample on a tick where the position moved. Returns where the
  /// picture stopped once the clock has run [kVideoStarvedAfter] past it
  /// with nothing new decoded; null otherwise.
  ///
  /// [running] is false while the player is paused or stalled, which decodes
  /// nothing for a reason of its own. [remaining] is the time left to the
  /// end, when the length is known.
  Duration? sample({
    required int decodedVideo,
    required Duration position,
    required bool running,
    Duration? remaining,
  }) {
    final last = _lastPosition;
    _lastPosition = position;
    // A jump is a seek, or ticks missed: the count starts again from where
    // playback is, so the refill after a seek is never read as starving.
    final jumped =
        last != null &&
        (position < last || position - last > const Duration(seconds: 5));
    final decoded = _decoded;
    final pictureAt = _pictureAt;
    if (decoded == null || decodedVideo > decoded || jumped) {
      // Positions before a jump don't measure playback after it.
      if (jumped) _recent.clear();
      _recent
        ..add((position: position, decoded: decodedVideo))
        ..removeWhere((x) => position - x.position > kStarvedRateWindow);
      final first = _recent.first;
      final span = position - first.position;
      if (!jumped &&
          decoded != null &&
          decodedVideo > decoded &&
          span >= const Duration(seconds: 1)) {
        _rate =
            (decodedVideo - first.decoded) *
            Duration.microsecondsPerSecond /
            span.inMicroseconds;
      }
      _decoded = decodedVideo;
      _pictureAt = position;
      return null;
    }
    // A backend whose counter never moved has no rate, and is never convicted
    // on its zeroes; nor is a video whose pictures came slowly anyway.
    final rate = _rate;
    if (rate == null || rate < kStarvedMinPictureRate || !running) return null;
    if (remaining != null && remaining <= kStarvedNearEnd) return null;
    return position - pictureAt! >= kVideoStarvedAfter ? pictureAt : null;
  }

  /// Forgets everything, for a new attempt.
  void reset() {
    _decoded = null;
    _pictureAt = null;
    _lastPosition = null;
    _recent.clear();
    _rate = null;
  }
}

/// Whether an end at [position] is a failure dressed as one (spec 2: "libVLC
/// says 'ended' more than 2 s before the known duration"): short of the
/// [duration], a truncated download; or with no duration at all, which can't
/// be measured, and "cannot tell" is treated as a failure so recovery still
/// gets its turn.
bool isFalseEnd({required Duration position, required Duration duration}) =>
    duration <= Duration.zero ||
    position < duration - const Duration(seconds: 2);

/// Whether a move to paused or stopped is one nobody asked for (spec 2,
/// *Detection*), which counts as a failure.
///
/// Asked for, it isn't: the viewer's pause or stop, the background policy's
/// pause and the app's own stop all count in the controller's
/// `pauseRequests` ([pauseRequests] moved since playback last ran,
/// [pauseRequestsWhenRunning]). An audio interruption pauses the engine
/// itself, and says so in [interruption]. With the app away ([foreground]
/// false) the platform may pause for reasons nobody reports. What is left is
/// macOS's pause at the end of a dropped connection's buffer (VLCKit's
/// `--play-and-pause`), and Android's stop after an error.
bool isUnaskedStop({
  required VlcPlaybackState state,
  required int pauseRequests,
  required int pauseRequestsWhenRunning,
  required VlcAudioInterruption interruption,
  required bool foreground,
}) =>
    (state == VlcPlaybackState.paused || state == VlcPlaybackState.stopped) &&
    pauseRequests == pauseRequestsWhenRunning &&
    interruption == VlcAudioInterruption.none &&
    foreground;

/// How long a wait over the picture keeps the display awake: past it, a wait
/// that may never end lets the phone sleep.
const Duration kWaitKeepsAwakeFor = Duration(minutes: 30);

/// The longest an open may take, progress or not, before it is given up on.
/// The same as [kStallRecoverWhileArrivingAfter]: room for the slowest start
/// worth waiting for, and no more.
const Duration kFirstFrameCap = Duration(seconds: 60);

/// What an opening attempt has to show for itself at one tick.
@immutable
class OpeningSample {
  const OpeningSample({
    this.state,
    this.prebuffer,
    this.readBytes = 0,
    this.demuxReadBytes = 0,
    this.decodedVideo = 0,
    this.decodedAudio = 0,
    this.startGated = false,
  });

  final VlcPlaybackState? state;

  /// libVLC's prebuffer, 0..1, while it fills.
  final double? prebuffer;

  final int readBytes;
  final int demuxReadBytes;
  final int decodedVideo;
  final int decodedAudio;

  /// Android: a play waiting at the font start gate (FORK.md 26), which is the
  /// app's wait, not the source's.
  final bool startGated;

  @override
  String toString() =>
      'OpeningSample(state: ${state?.name}, prebuffer: $prebuffer, '
      'read: $readBytes, demuxed: $demuxReadBytes, video: $decodedVideo, '
      'audio: $decodedAudio, gated: $startGated)';
}

/// Whether to go on waiting for an opening attempt's first picture.
enum FirstFrameVerdict { wait, giveUp }

/// The first-frame deadline, counted from progress (the findings' Part 3:
/// "the 30 s 'never started' deadline can fire just as a slow start
/// succeeds").
///
/// On the TV emulator libVLC joined a live stream, sent nothing for 29 s, then
/// fetched four segments and showed its first picture; the deadline, counted
/// from the open, threw that picture away a second later. Counted from the
/// last sign of progress, a start that is getting somewhere is left to finish,
/// up to [kFirstFrameCap]. Torrents keep [kTorrentStallRecoverAfter] from
/// the open: their progress is pieces arriving, which the engine can't see.
class FirstFrameWatch {
  FirstFrameWatch({this.torrent = false}) {
    restart();
  }

  final bool torrent;

  late DateTime _openedAt;
  late DateTime _progressAt;
  OpeningSample _last = const OpeningSample();

  /// Starts again from now: a new attempt, or a wait that was nobody's (the
  /// app off screen, a remounted player).
  void restart() {
    _openedAt = _progressAt = clock.now();
    _last = const OpeningSample();
  }

  /// Records [sample]. True when it shows progress since the last one: the
  /// state moving on, the prebuffer appearing or rising, any byte or decoder
  /// count rising, or Android's start gate holding the play.
  bool sample(OpeningSample sample) {
    final last = _last;
    _last = sample;
    final prebuffer = sample.prebuffer;
    final progress =
        _rank(sample.state) > _rank(last.state) ||
        (prebuffer != null && prebuffer > (last.prebuffer ?? -1)) ||
        sample.readBytes > last.readBytes ||
        sample.demuxReadBytes > last.demuxReadBytes ||
        sample.decodedVideo > last.decodedVideo ||
        sample.decodedAudio > last.decodedAudio ||
        sample.startGated;
    if (progress) _progressAt = clock.now();
    // A play the gate holds hasn't started: the cap counts from its opening
    // (up to 60 s on a slow device, FORK.md 26).
    if (sample.startGated) _openedAt = clock.now();
    return progress;
  }

  FirstFrameVerdict get verdict {
    final now = clock.now();
    final open = now.difference(_openedAt);
    if (torrent) {
      return open >= kTorrentStallRecoverAfter
          ? FirstFrameVerdict.giveUp
          : FirstFrameVerdict.wait;
    }
    if (open >= kFirstFrameCap ||
        now.difference(_progressAt) >= kFirstFrameDeadline) {
      return FirstFrameVerdict.giveUp;
    }
    return FirstFrameVerdict.wait;
  }

  static int _rank(VlcPlaybackState? state) => switch (state) {
    VlcPlaybackState.opening => 1,
    VlcPlaybackState.buffering => 2,
    VlcPlaybackState.playing || VlcPlaybackState.paused => 3,
    _ => 0,
  };
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
///
/// [unreachable] are the candidates the reachability check found dead. They
/// are walked last rather than dropped: a slow host, or one that refuses the
/// probe's HEAD and ranged GET, reads as dead and still streams. Before
/// everything else, though, they would each cost the full stall deadline.
///
/// [cannotSeek] are the candidates whose servers ignore byte ranges, for a
/// walk that resumes mid-film: one of them would start it again from the
/// top. Walked after the rest, but before the ones found dead - a film from
/// the start still beats none.
int? nextFailoverIndex({
  required int from,
  required int total,
  required Set<int> tried,
  Set<int> unreachable = const <int>{},
  Set<int> cannotSeek = const <int>{},
}) {
  if (total <= 0) return null;
  int? fromTheStart;
  int? lastResort;
  for (var step = 1; step <= total; step++) {
    final candidate = (from + step) % total;
    if (tried.contains(candidate)) continue;
    if (unreachable.contains(candidate)) {
      lastResort ??= candidate;
    } else if (cannotSeek.contains(candidate)) {
      fromTheStart ??= candidate;
    } else {
      return candidate;
    }
  }
  return fromTheStart ?? lastResort;
}

/// The source to resume on: [preferred], unless the check found its server
/// ignores byte ranges - libVLC would start it from the top, losing the
/// viewer's place - and has vouched for one that can seek.
///
/// Only a settled answer moves it: a probe still out may yet say the same.
int resumeSourceIndex({
  required int preferred,
  required int total,
  required Map<int, ProbeOutcome> probes,
}) {
  if (probes[preferred] != ProbeOutcome.unseekable) return preferred;
  for (var index = 0; index < total; index++) {
    if (probes[index] == ProbeOutcome.healthy) return index;
  }
  return preferred;
}

/// Where to go when the source at [except] turns out unreachable while it
/// opens: the first candidate the check has vouched for that has not failed,
/// or null when none has.
///
/// Back to a known-good source rather than on down the list: the next
/// candidate is as unproven as the one just abandoned. Null means there is
/// nowhere proven to go, and the caller should keep opening rather than
/// abandon a source on the probe's word alone - it is wrong about slow hosts.
///
/// One that can be sought in comes first; one whose server ignores byte
/// ranges plays too, only from its start.
int? firstReachableIndex({
  required int total,
  required Map<int, ProbeOutcome> probes,
  required Set<int> failed,
  required int except,
}) {
  int? fromTheStart;
  for (var index = 0; index < total; index++) {
    if (index == except || failed.contains(index)) continue;
    final probe = probes[index];
    if (probe == ProbeOutcome.healthy) return index;
    if (probe == ProbeOutcome.unseekable) fromTheStart ??= index;
  }
  return fromTheStart;
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

/// The `--adaptive-maxheight` a source is opened with.
///
/// [pick] is the viewer's choice from the player's Quality tab, null for
/// Auto. It is taken as it is - above the device's own rung too, which a
/// media option may do - and [stepDownFrom] still lowers it for a device
/// that cannot keep up.
///
/// Auto is the smaller of [deviceCap], the device's rung lowered by any
/// step-down ([adaptiveMaxHeightFor]), and [preferenceHeight], the height of
/// the Wi-Fi or mobile data quality preference in force (null for Any). A
/// preference below a stream's lowest rendition plays that lowest one.
int renditionCapFor({
  required int deviceCap,
  int? pick,
  int? preferenceHeight,
}) {
  if (pick != null) return pick;
  if (preferenceHeight != null && preferenceHeight < deviceCap) {
    return preferenceHeight;
  }
  return deviceCap;
}

/// Whether a video that stopped showing pictures gets one reopen decoding in
/// software (spec 1.6): only on Android, where the hardware switch reaches
/// the decoder, only while hardware decoding is in force, and once.
///
/// What it answers is MediaCodec dying mid-play, which the video health check
/// sees as no pictures while the clock runs on. Pictures the video output
/// dropped in that window ([lostInWindow] above 0) were decoded, so the
/// decoder is alive and it is the output that failed (Android's surface
/// stall): software decoding would bring no picture back, so that goes the
/// ordinary way. So does a second failure.
bool shouldRetryInSoftware({
  required TargetPlatform platform,
  required bool hardwareDecoding,
  required bool alreadySoftware,
  required int lostInWindow,
}) =>
    platform == TargetPlatform.android &&
    hardwareDecoding &&
    !alreadySoftware &&
    lostInWindow <= 0;

/// The rendition cap once the CPU decodes: what [adaptiveMaxHeightFor] gives
/// with no hardware decoder, and never above [currentCap].
int softwareRetryCap({
  required DeviceTier tier,
  required int panelHeightPx,
  required int currentCap,
}) {
  final software = adaptiveMaxHeightFor(
    tier: tier,
    panelHeightPx: panelHeightPx,
    hardwareDecode: false,
  );
  return software < currentCap ? software : currentCap;
}
