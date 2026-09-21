import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/buffered_ahead.dart';

/// The estimate behind the buffered segment of the seek bar.
///
/// libVLC 3 publishes no buffered range, so this is derived from byte
/// counters. Every rule here exists because the alternative is a bar that
/// confidently shows a wrong number, which is worse than a bar that shows
/// nothing - a viewer who learns the buffered line lies stops reading it.
void main() {
  group('the ordinary case', () {
    test('read-ahead is bytes fetched over the rate they are consumed at', () {
      // 1 MB/s consumed, 5 MB sitting ahead of the demuxer: five seconds.
      final ahead = bufferedAhead(
        readBytes: 15000000,
        demuxReadBytes: 10000000,
        previousDemuxReadBytes: 9000000,
        sampleInterval: const Duration(seconds: 1),
      );

      expect(ahead, isNotNull);
      expect(ahead!.inSeconds, 5);
    });

    test('a slower interval measures the same rate', () {
      // Same 1 MB/s, sampled over two seconds instead of one.
      final ahead = bufferedAhead(
        readBytes: 15000000,
        demuxReadBytes: 10000000,
        previousDemuxReadBytes: 8000000,
        sampleInterval: const Duration(seconds: 2),
      );

      expect(ahead!.inSeconds, 5);
    });
  });

  group('refusing to guess', () {
    test('a demuxer that consumed nothing gives no rate', () {
      // Paused or stalled. Dividing by this would be infinity.
      expect(
        bufferedAhead(
          readBytes: 15000000,
          demuxReadBytes: 10000000,
          previousDemuxReadBytes: 10000000,
          sampleInterval: const Duration(seconds: 1),
        ),
        isNull,
      );
    });

    test('counters that reset under us are refused, not believed', () {
      // A reopen resets them natively, and one can land before the other.
      expect(
        bufferedAhead(
          readBytes: 500,
          demuxReadBytes: 10000000,
          previousDemuxReadBytes: 12000000,
          sampleInterval: const Duration(seconds: 1),
        ),
        isNull,
      );
    });

    test('an absurd read-ahead is an artefact, not a big buffer', () {
      // 1 KB/s consumed with 1 GB ahead is eleven days. Something is wrong -
      // most likely the demuxer barely moved - and the bar must not say so.
      expect(
        bufferedAhead(
          readBytes: 1000000000,
          demuxReadBytes: 1000,
          previousDemuxReadBytes: 0,
          sampleInterval: const Duration(seconds: 1),
        ),
        isNull,
      );
    });

    test('a zero interval has no rate to offer', () {
      expect(
        bufferedAhead(
          readBytes: 15000000,
          demuxReadBytes: 10000000,
          previousDemuxReadBytes: 9000000,
          sampleInterval: Duration.zero,
        ),
        isNull,
      );
    });

    test('the demuxer caught up, which is zero ahead and not unknown', () {
      // A real answer: nothing is buffered. Distinct from null, because the
      // bar should show an empty buffer rather than hide the segment.
      expect(
        bufferedAhead(
          readBytes: 10000000,
          demuxReadBytes: 10000000,
          previousDemuxReadBytes: 9000000,
          sampleInterval: const Duration(seconds: 1),
        ),
        Duration.zero,
      );
    });
  });

  group('a seek, which is where the counters part company', _seekTests);

  group('turning it into a bar', () {
    test('the segment ends where the buffer runs out', () {
      final fraction = bufferedFraction(
        position: const Duration(minutes: 10),
        duration: const Duration(minutes: 100),
        ahead: const Duration(minutes: 5),
      );

      expect(fraction, closeTo(0.15, 1e-9));
    });

    test('a buffer past the end of the film stops at the end', () {
      final fraction = bufferedFraction(
        position: const Duration(minutes: 99),
        duration: const Duration(minutes: 100),
        ahead: const Duration(minutes: 5),
      );

      expect(fraction, 1.0);
    });

    test('a live stream has no length to measure against', () {
      expect(
        bufferedFraction(
          position: const Duration(minutes: 10),
          duration: Duration.zero,
          ahead: const Duration(minutes: 5),
        ),
        isNull,
      );
    });

    test('no estimate draws no segment', () {
      expect(
        bufferedFraction(
          position: const Duration(minutes: 10),
          duration: const Duration(minutes: 100),
          ahead: null,
        ),
        isNull,
      );
    });
  });
}

/// What a seek does to the two counters, and why the band used to vanish.
///
/// `readBytes - demuxReadBytes` is only a buffer while every byte the access
/// reads is eventually demuxed. A seek breaks that: libVLC's prefetch filter
/// empties its window when the target lands past the end of it, and those
/// bytes are counted as read and never as demuxed. The gap stays that much
/// too wide for the rest of the session.
///
/// The numbers below are a stream running at 1 MB/s, sampled once a second,
/// which is what the player actually does.
void _seekTests() {
  const second = Duration(seconds: 1);
  const rate = 1000000; // bytes per second, and so bytes per sample

  /// Drives the estimator through [samples] seconds of ordinary playback,
  /// keeping a full [bufferBytes] buffer ahead of the demuxer.
  ({int read, int demux, Duration position, Duration at, int seeks}) play(
    BufferedAheadEstimator estimator, {
    required int read,
    required int demux,
    required Duration position,
    required Duration at,
    required int seeks,
    required int bufferBytes,
    int samples = 1,
  }) {
    for (var i = 0; i < samples; i++) {
      demux += rate;
      read = demux + bufferBytes;
      position += second;
      at += second;
      estimator.sample(
        readBytes: read,
        demuxReadBytes: demux,
        position: position,
        at: at,
        seekRequests: seeks,
      );
    }
    return (read: read, demux: demux, position: position, at: at, seeks: seeks);
  }

  test('an untouched stream reports the buffer it holds', () {
    final estimator = BufferedAheadEstimator();
    final s = play(
      estimator,
      read: 0,
      demux: 0,
      position: Duration.zero,
      at: Duration.zero,
      seeks: 0,
      bufferBytes: 8 * rate,
      samples: 4,
    );

    final ahead = estimator.sample(
      readBytes: s.demux + rate + 8 * rate,
      demuxReadBytes: s.demux + rate,
      position: s.position + second,
      at: s.at + second,
      seekRequests: 0,
    );

    expect(ahead, isNotNull);
    expect(ahead!.inSeconds, 8);
    expect(estimator.strandedBytes, 0);
  });

  test('a forward seek past the buffer empties it, and says so', () {
    final estimator = BufferedAheadEstimator();
    final s = play(
      estimator,
      read: 0,
      demux: 0,
      position: Duration.zero,
      at: Duration.zero,
      seeks: 0,
      bufferBytes: 8 * rate,
      samples: 4,
    );

    // Ten minutes forward. The prefetch window is discarded: the access
    // starts again at the new offset, so the demuxer gets almost nothing this
    // second and the 8 MB that was buffered is never demuxed.
    final ahead = estimator.sample(
      readBytes: s.read + 200000,
      demuxReadBytes: s.demux + 100000,
      position: s.position + const Duration(minutes: 10),
      at: s.at + second,
      seekRequests: 1,
    );

    expect(
      ahead,
      Duration.zero,
      reason: 'the buffer really is empty, and an empty buffer is a fact '
          'rather than the "I do not know" that hides the band',
    );
  });

  test('and the band comes back as the buffer refills', () {
    final estimator = BufferedAheadEstimator();
    final s = play(
      estimator,
      read: 0,
      demux: 0,
      position: Duration.zero,
      at: Duration.zero,
      seeks: 0,
      bufferBytes: 8 * rate,
      samples: 4,
    );

    var read = s.read + 200000;
    var demux = s.demux + 100000;
    var position = s.position + const Duration(minutes: 10);
    var at = s.at + second;
    estimator.sample(
      readBytes: read,
      demuxReadBytes: demux,
      position: position,
      at: at,
      seekRequests: 1,
    );

    // Three seconds of refilling: the demuxer consumes its 1 MB a second and
    // the access runs 3 MB ahead of it.
    //
    // `readBytes` is cumulative and still carries the bytes the seek stranded,
    // so the gap between the counters is those plus the 3 MB actually held.
    // Writing it as a bare 3 MB is the mistake the correction exists to stop
    // anyone making, including here.
    final stranded = estimator.strandedBytes;
    for (var i = 0; i < 3; i++) {
      demux += rate;
      read = demux + stranded + 3 * rate;
      position += second;
      at += second;
    }
    final ahead = estimator.sample(
      readBytes: read,
      demuxReadBytes: demux,
      position: position,
      at: at,
      seekRequests: 1,
    );

    expect(ahead, isNotNull, reason: 'this is the regression: it used to be '
        'suppressed as an absurd read-ahead and the band stayed blank');
    expect(ahead!.inSeconds, closeTo(3, 1));
  });

  test('the old arithmetic would have claimed ten minutes of buffer', () {
    // The same sample, read the way it was before stranded bytes were
    // accounted for: the 8 MB discarded window plus the 3 MB really held,
    // over a 1 MB/s rate. Eleven seconds claimed for three seconds held - and
    // it compounds with every seek until it trips the cap and the band
    // disappears for good.
    final naive = bufferedAhead(
      readBytes: 11 * rate,
      demuxReadBytes: 0,
      previousDemuxReadBytes: -rate,
      sampleInterval: second,
    );

    expect(naive!.inSeconds, 11);

    final corrected = bufferedAhead(
      readBytes: 11 * rate,
      demuxReadBytes: 0,
      previousDemuxReadBytes: -rate,
      sampleInterval: second,
      strandedBytes: 8 * rate,
    );

    expect(corrected!.inSeconds, 3);
  });

  test('a seek inside the buffer spends part of it, not all of it', () {
    final estimator = BufferedAheadEstimator();
    final s = play(
      estimator,
      read: 0,
      demux: 0,
      position: Duration.zero,
      at: Duration.zero,
      seeks: 0,
      bufferBytes: 30 * rate,
      samples: 4,
    );

    // Ten seconds forward with thirty buffered: the window is not discarded,
    // the demuxer just repositions over ten seconds of it. Nine of those are
    // skipped and one is the second that elapsed.
    final ahead = estimator.sample(
      readBytes: s.read + rate,
      demuxReadBytes: s.demux + rate,
      position: s.position + const Duration(seconds: 10),
      at: s.at + second,
      seekRequests: 1,
    );

    expect(ahead, isNotNull);
    expect(
      ahead!.inSeconds,
      closeTo(21, 1),
      reason: 'thirty seconds held, nine of them skipped past',
    );
  });

  test('scrubbing repeatedly does not accumulate a phantom buffer', () {
    final estimator = BufferedAheadEstimator();
    var read = 0;
    var demux = 0;
    var position = Duration.zero;
    var at = Duration.zero;

    for (var seek = 1; seek <= 5; seek++) {
      // Settle with 8 MB buffered.
      for (var i = 0; i < 3; i++) {
        demux += rate;
        read = demux + 8 * rate;
        position += second;
        at += second;
        estimator.sample(
          readBytes: read,
          demuxReadBytes: demux,
          position: position,
          at: at,
          seekRequests: seek - 1,
        );
      }
      // Scrub five minutes on, discarding the window.
      demux += 100000;
      read += 200000;
      position += const Duration(minutes: 5);
      at += second;
      estimator.sample(
        readBytes: read,
        demuxReadBytes: demux,
        position: position,
        at: at,
        seekRequests: seek,
      );
    }

    // Refill to a known 4 MB and read it back.
    for (var i = 0; i < 3; i++) {
      demux += rate;
      read = demux + estimator.strandedBytes + 4 * rate;
      position += second;
      at += second;
    }
    final ahead = estimator.sample(
      readBytes: read,
      demuxReadBytes: demux,
      position: position,
      at: at,
      seekRequests: 5,
    );

    expect(ahead, isNotNull, reason: 'five seeks used to be five times the '
        'phantom, and the band never returned');
    expect(ahead!.inSeconds, closeTo(4, 1));
  });

  test('a backward seek strands nothing', () {
    final estimator = BufferedAheadEstimator();
    final s = play(
      estimator,
      read: 0,
      demux: 0,
      position: const Duration(minutes: 5),
      at: Duration.zero,
      seeks: 0,
      bufferBytes: 8 * rate,
      samples: 4,
    );

    estimator.sample(
      readBytes: s.read + rate,
      demuxReadBytes: s.demux + rate,
      position: s.position - const Duration(seconds: 30),
      at: s.at + second,
      seekRequests: 1,
    );

    expect(
      estimator.strandedBytes,
      0,
      reason: 'going back re-reads bytes that were already counted, so the '
          'gap closes on its own',
    );
  });

  test('a media change forgets the correction but keeps the rate baseline', () {
    final estimator = BufferedAheadEstimator();
    final s = play(
      estimator,
      read: 0,
      demux: 0,
      position: Duration.zero,
      at: Duration.zero,
      seeks: 0,
      bufferBytes: 8 * rate,
      samples: 3,
    );
    estimator.sample(
      readBytes: s.read,
      demuxReadBytes: s.demux + 100000,
      position: s.position + const Duration(minutes: 10),
      at: s.at + second,
      seekRequests: 1,
    );
    expect(estimator.strandedBytes, greaterThan(0));

    estimator.noteMediaChanged();
    expect(estimator.strandedBytes, 0);

    // The baseline survives, because this is called on the way *into* a media
    // as well - dropping it there would cost a second of blank band at the
    // start of every stream. Counters that really restarted invalidate it on
    // their own: the delta goes negative and that is already refused.
    expect(
      estimator.sample(
        readBytes: 1000,
        demuxReadBytes: 500,
        position: Duration.zero,
        at: s.at + const Duration(seconds: 2),
        seekRequests: 1,
      ),
      isNull,
      reason: 'a demux counter that went backwards is a reset, not a rate',
    );
  });
}
