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
