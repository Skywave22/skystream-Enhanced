/// How far ahead of the playhead the stream has actually been fetched.
///
/// libVLC 3 publishes no buffered range. There is a buffering *percentage*
/// while a media opens and nothing at all once it is playing, so the figure
/// behind a YouTube-style bar has to be derived from the byte counters, and it
/// is an estimate rather than a reading.
///
/// The RATE is derived from a delta, never from the totals. The totals are
/// cumulative for the media, so after a seek they no longer correspond to the
/// position at all - ten minutes in, having skipped there, the demuxer has
/// read seconds of bytes, and dividing one by the other says the stream is
/// buffered for hours. Two samples a known interval apart give the rate the
/// demuxer is really consuming at, which survives a seek because both ends of
/// the delta are on the same side of it.
///
/// The LEVEL cannot be a delta - a buffer is a quantity, not a rate - so it is
/// `readBytes - demuxReadBytes`, and that subtraction has a leak in it that
/// this library now accounts for explicitly. See [BufferedAheadEstimator].
library;

import 'dart:math' as math;

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
///
/// [strandedBytes] is taken off the gap between the two counters before any of
/// that. A gap on its own is not a buffer; see [BufferedAheadEstimator] for
/// what leaks into it and why.
Duration? bufferedAhead({
  required int readBytes,
  required int demuxReadBytes,
  required int previousDemuxReadBytes,
  required Duration sampleInterval,
  int strandedBytes = 0,
}) {
  if (sampleInterval <= Duration.zero) return null;

  final consumed = demuxReadBytes - previousDemuxReadBytes;
  if (consumed <= 0) return null;

  final ahead = readBytes - demuxReadBytes - strandedBytes;
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

/// Keeps the running estimate honest across seeks.
///
/// THE LEAK. `readBytes - demuxReadBytes` is only the buffer's contents while
/// every byte the access reads is eventually handed to the demuxer. A seek
/// breaks that. libVLC 3's prefetch filter, which is the buffer this figure
/// describes, empties its window whenever the target lands past the end of it:
///
/// ```c
/// if (sys->can_seek
///  && history >= (sys->buffer_length + sys->seek_threshold))
/// {
///     if (ThreadSeek(stream, stream_offset) == 0)
///     {
///         sys->buffer_offset = stream_offset;
///         sys->buffer_length = 0;      // thrown away
///     }
/// }
/// ```
///
/// Those bytes were counted in `readBytes` when they arrived and will never
/// be counted in `demuxReadBytes`, because they were discarded rather than
/// demuxed. A seek that lands *inside* the window leaks in the same way for a
/// smaller amount: the demuxer repositions over bytes it never reads.
///
/// Either way the gap between the counters is permanently wider than the
/// buffer by whatever was skipped, and it never closes. Left alone the figure
/// grows with every seek until `ahead / rate` clears
/// [kMaxReportableBufferedAhead] and [bufferedAhead] starts refusing to answer
/// at all - which is what a viewer sees as the buffered band vanishing after a
/// seek and not coming back.
///
/// THE FIX. Carry the leaked total. Each seek strands about
/// `skipped * bytesPerSecond` more bytes, capped by the gap itself, and that
/// running total is subtracted before the gap is read as a buffer.
///
/// It is still an estimate: the rate it converts the skip with is the measured
/// one, so the correction inherits its error. It errs towards *under*-reporting
/// - a band that is shorter than the real buffer costs a viewer nothing, and
/// one that is longer is the lie this whole library is written to avoid.
class BufferedAheadEstimator {
  /// Bytes the access has read that the demuxer will never consume.
  ///
  /// Exposed for tests and for anyone debugging a band that looks wrong; the
  /// screen has no reason to read it.
  int get strandedBytes => _stranded;
  int _stranded = 0;

  int? _previousDemuxReadBytes;
  Duration _lastSampleAt = Duration.zero;

  /// The position at the previous sample, or null when there has not been one
  /// to measure a skip against.
  Duration? _lastPosition;
  int _seenSeekRequests = 0;

  /// A seek has been noticed and is waiting for a sample good enough to
  /// convert it into bytes. Held rather than applied immediately because the
  /// sample that spans a seek is exactly the one whose rate cannot be trusted.
  Duration? _pendingSkip;

  /// Drops the seek correction, for a media change.
  ///
  /// The correction describes one media's counters and means nothing for the
  /// next, so it goes. The *rate* baseline deliberately stays: this is called
  /// on the way into a media as well as out of one - once when the attempt
  /// begins and again when the engine is handed the stream - and throwing the
  /// baseline away at the second of those would cost a sample, and a second of
  /// blank band, every time a stream starts. Where the counters really do
  /// restart, the baseline invalidates itself: the next delta is negative and
  /// [bufferedAhead] already refuses those.
  ///
  /// [_seenSeekRequests] stays too. The controller's counter does not restart
  /// with the media, so zeroing it here would invent a seek on the next
  /// sample.
  void noteMediaChanged() {
    _stranded = 0;
    _pendingSkip = null;
    _lastPosition = null;
  }

  /// One stats sample. Returns the read-ahead, or null when it cannot be known
  /// and the band should therefore be drawn as nothing.
  ///
  /// [at] is any monotonic clock; only differences are used. [seekRequests] is
  /// the controller's own count, which is what makes a seek visible here at
  /// all - a position jump would also catch a stall, and a stall is the one
  /// thing that must not be mistaken for a skip.
  Duration? sample({
    required int readBytes,
    required int demuxReadBytes,
    required Duration position,
    required Duration at,
    required int seekRequests,
    double speed = 1.0,
  }) {
    final previous = _previousDemuxReadBytes;
    final interval = at - _lastSampleAt;
    _previousDemuxReadBytes = demuxReadBytes;
    _lastSampleAt = at;

    final lastPosition = _lastPosition;
    _lastPosition = position;

    if (seekRequests != _seenSeekRequests) {
      _seenSeekRequests = seekRequests;
      // Only measurable against a previous sample. Without one there is
      // nothing stranded to measure anyway: this is the seek a player makes on
      // its way into a stream - to a resume point, or to the start - and it
      // happens before there is a buffer to discard. Taken at face value it
      // would read as "the whole resume offset was skipped" and empty a band
      // that was never filled.
      if (lastPosition != null && previous != null) {
        // What the playhead covered without the demuxer reading it. The sample
        // interval's own worth of playback is taken off, because that part was
        // watched rather than skipped.
        final moved = position - lastPosition;
        final played = interval * (speed <= 0 ? 1.0 : speed);
        final skipped = moved - played;
        // A backward seek strands nothing: the demuxer re-reads bytes it has
        // already counted, so the gap closes on its own and the band simply
        // under-reports until it has caught back up.
        _pendingSkip = skipped > Duration.zero ? skipped : Duration.zero;
      }
    }

    if (previous == null) return null;

    final consumed = demuxReadBytes - previous;
    final seconds = interval.inMicroseconds / 1e6;
    if (consumed <= 0 || seconds <= 0) return null;
    final bytesPerSecond = consumed / seconds;
    if (!bytesPerSecond.isFinite || bytesPerSecond <= 0) return null;

    final pending = _pendingSkip;
    if (pending != null) {
      _pendingSkip = null;
      final skippedBytes =
          (pending.inMicroseconds / 1e6 * bytesPerSecond).round();
      // Never strand more than the gap holds: the cap is what turns a scrub
      // across the whole film into "the buffer is empty" rather than a
      // negative one.
      _stranded = math.min(readBytes - demuxReadBytes, _stranded + skippedBytes);
      if (_stranded < 0) _stranded = 0;
    }

    return bufferedAhead(
      readBytes: readBytes,
      demuxReadBytes: demuxReadBytes,
      previousDemuxReadBytes: previous,
      sampleInterval: interval,
      strandedBytes: _stranded,
    );
  }
}
