/// Telling a stuttering source apart from a struggling device.
///
/// "The video is not smooth" has two completely different causes and the fix
/// for one makes the other worse: dropping to a lower rendition rescues a
/// decoder that cannot keep up, and does nothing at all for a stream arriving
/// corrupt. libVLC counts both, and the counters say which is happening.
///
/// Every figure here is a DELTA over one measurement window. The counters are
/// cumulative for the media, so absolute values only say what has happened
/// since it opened - a film that stuttered badly in its first minute would
/// read as unwell for the rest of the evening.
library;

/// What the counters say is wrong, if anything.
enum PlaybackSmoothness {
  /// Pictures are arriving and being shown. Nothing to report.
  fine,

  /// The decoder is being handed more than it can finish in time, so pictures
  /// are being thrown away late. A device problem: this is what a lower
  /// rendition fixes.
  decoderBehind,

  /// The stream itself is arriving damaged - bytes the demuxer could not parse.
  /// A source problem: another provider will fix it, a lower rendition will
  /// not.
  sourceCorrupt,

  /// Timestamps are jumping, so the stream is missing pieces or splicing badly.
  /// Also a source problem, and the usual signature of a flaky connection or a
  /// packager stitching segments together wrongly.
  sourceDiscontinuous,

  /// The decoder is producing pictures that never reach the screen. Neither
  /// the source nor the decoder: the video output is dropping them.
  outputStalled,

  /// Not enough evidence yet, or the backend does not keep counters.
  unknown,
}

/// The share of pictures that may be lost before the decoder is judged behind.
const double kSmoothnessLostShare = 0.05;

/// Fewest pictures in a window before a share means anything. A handful of
/// frames can be lost to a single scheduling hiccup on any device.
const int kSmoothnessMinPictures = 50;

/// Classifies one measurement window.
///
/// Ordered by which answer is most actionable when several are true at once. A
/// corrupt stream also makes a decoder look bad - it is fed rubbish and throws
/// it away - so corruption is reported first; treating that as a slow decoder
/// would send someone stepping renditions down forever on a bad source.
PlaybackSmoothness classifySmoothness({
  required bool statsAvailable,
  required Duration measuredFor,
  required int displayed,
  required int lost,
  required int corrupted,
  required int discontinuity,
  required int decoded,
}) {
  if (!statsAvailable || measuredFor <= Duration.zero) {
    return PlaybackSmoothness.unknown;
  }
  if (corrupted > 0) return PlaybackSmoothness.sourceCorrupt;
  if (discontinuity > 0) return PlaybackSmoothness.sourceDiscontinuous;

  // Decoded but never shown. Counted before the lost-share test because the
  // share needs displayed pictures to divide by, and this is the case where
  // there are none.
  if (decoded >= kSmoothnessMinPictures && displayed <= 0) {
    return PlaybackSmoothness.outputStalled;
  }

  final total = displayed + lost;
  if (total < kSmoothnessMinPictures) return PlaybackSmoothness.unknown;
  if (lost / total >= kSmoothnessLostShare) {
    return PlaybackSmoothness.decoderBehind;
  }
  return PlaybackSmoothness.fine;
}

/// A line for the log, naming the side at fault and the numbers behind it.
///
/// Written for whoever is reading a bug report, so it says what to do rather
/// than only what happened.
String smoothnessReport(
  PlaybackSmoothness verdict, {
  required int displayed,
  required int lost,
  required int corrupted,
  required int discontinuity,
}) {
  final counts =
      'displayed=$displayed lost=$lost corrupted=$corrupted '
      'discontinuity=$discontinuity';
  return switch (verdict) {
    PlaybackSmoothness.fine => 'playback smooth ($counts)',
    PlaybackSmoothness.decoderBehind =>
      'this device cannot decode this rendition in time - try a lower '
          'quality ($counts)',
    PlaybackSmoothness.sourceCorrupt =>
      'the source is delivering damaged data - try another source, quality '
          'will not help ($counts)',
    PlaybackSmoothness.sourceDiscontinuous =>
      'the source is skipping or splicing badly - usually the connection or '
          'the packager, not this device ($counts)',
    PlaybackSmoothness.outputStalled =>
      'pictures are decoded but never shown - the video output is dropping '
          'them ($counts)',
    PlaybackSmoothness.unknown => 'not enough evidence yet ($counts)',
  };
}
