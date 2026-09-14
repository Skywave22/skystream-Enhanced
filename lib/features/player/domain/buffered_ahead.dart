/// How far ahead of the playhead the stream has actually been fetched.
///
/// libVLC 3 publishes no buffered range. There is a buffering *percentage*
/// while a media opens and nothing at all once it is playing, so the figure
/// behind a YouTube-style bar has to be derived from the byte counters, and it
/// is an estimate rather than a reading.
///
/// Derived from a delta, never from the totals. The totals are cumulative for
/// the media, so after a seek they no longer correspond to the position at all
/// - ten minutes in, having skipped there, the demuxer has read seconds of
/// bytes, and dividing one by the other says the stream is buffered for hours.
/// Two samples a known interval apart give the rate the demuxer is really
/// consuming at, which survives a seek because both ends of the delta are on
/// the same side of it.
library;

/// The largest read-ahead worth reporting.
///
/// Past this the figure is far more likely to be an artefact - a stalled
/// demuxer, a counter reset, an adaptive demuxer fetching a whole segment - than
/// a genuinely enormous buffer, and a progress bar that claims an hour is
/// buffered teaches a viewer to distrust it.
const Duration kMaxReportableBufferedAhead = Duration(minutes: 10);

/// Bytes fetched but not yet handed to the demuxer, expressed as playing time.
///
/// Returns null whenever the answer would be a guess, and the bar then draws
/// nothing rather than something wrong:
///
///  * the sample interval is zero or negative, so there is no rate;
///  * the demuxer consumed nothing between samples - paused, stalled, or a
///    counter that was reset under us - so the divisor is meaningless;
///  * the access has read fewer bytes than the demuxer consumed, which happens
///    across a reopen when one counter resets before the other;
///  * the result lands past [kMaxReportableBufferedAhead].
Duration? bufferedAhead({
  required int readBytes,
  required int demuxReadBytes,
  required int previousDemuxReadBytes,
  required Duration sampleInterval,
}) {
  if (sampleInterval <= Duration.zero) return null;

  final consumed = demuxReadBytes - previousDemuxReadBytes;
  if (consumed <= 0) return null;

  final ahead = readBytes - demuxReadBytes;
  if (ahead <= 0) return Duration.zero;

  final bytesPerSecond = consumed / (sampleInterval.inMicroseconds / 1e6);
  if (!bytesPerSecond.isFinite || bytesPerSecond <= 0) return null;

  final seconds = ahead / bytesPerSecond;
  if (!seconds.isFinite || seconds < 0) return null;

  final result = Duration(microseconds: (seconds * 1e6).round());
  return result > kMaxReportableBufferedAhead ? null : result;
}

/// Where the buffered segment of a seek bar should end, as a fraction of the
/// media.
///
/// Clamped to the bar: a buffer that runs past the end of a film is an
/// artefact of the estimate, not something to draw off the edge. Returns null
/// when [ahead] is null or the duration is unknown, which is every live stream.
double? bufferedFraction({
  required Duration position,
  required Duration duration,
  required Duration? ahead,
}) {
  if (ahead == null || duration <= Duration.zero) return null;
  final end = position + ahead;
  final fraction = end.inMicroseconds / duration.inMicroseconds;
  if (!fraction.isFinite) return null;
  return fraction.clamp(0.0, 1.0);
}
