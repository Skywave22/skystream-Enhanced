import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/smoothness.dart';

/// Which side a stutter is coming from.
///
/// The two causes have opposite fixes - a decoder that cannot keep up wants a
/// lower rendition, a source arriving damaged wants a different source - so
/// naming the wrong one sends someone stepping quality down forever on a bad
/// stream, or swapping sources to escape their own hardware.
void main() {
  PlaybackSmoothness classify({
    bool statsAvailable = true,
    Duration measuredFor = const Duration(seconds: 8),
    int displayed = 240,
    int lost = 0,
    int corrupted = 0,
    int discontinuity = 0,
    int decoded = 240,
  }) => classifySmoothness(
    statsAvailable: statsAvailable,
    measuredFor: measuredFor,
    displayed: displayed,
    lost: lost,
    corrupted: corrupted,
    discontinuity: discontinuity,
    decoded: decoded,
  );

  group('healthy playback', () {
    test('pictures arriving and being shown is fine', () {
      expect(classify(), PlaybackSmoothness.fine);
    });

    test('a handful of lost frames is not a verdict', () {
      // Any device drops the odd frame to a scheduling hiccup.
      expect(classify(displayed: 240, lost: 5), PlaybackSmoothness.fine);
    });
  });

  group('the device', () {
    test('losing a real share of pictures is the decoder falling behind', () {
      expect(
        classify(displayed: 200, lost: 40),
        PlaybackSmoothness.decoderBehind,
      );
    });

    test('decoded but never shown is the output, not the decoder', () {
      expect(
        classify(displayed: 0, lost: 0, decoded: 240),
        PlaybackSmoothness.outputStalled,
      );
    });
  });

  group('the source', () {
    test('damaged bytes are the source, whatever the decoder looks like', () {
      // The ordering that matters: a corrupt stream ALSO makes a decoder look
      // bad, because it is fed rubbish and throws it away. Reporting that as a
      // slow decoder sends someone down the rendition ladder forever.
      expect(
        classify(displayed: 200, lost: 40, corrupted: 12),
        PlaybackSmoothness.sourceCorrupt,
      );
    });

    test('jumping timestamps are the source too', () {
      expect(
        classify(discontinuity: 3),
        PlaybackSmoothness.sourceDiscontinuous,
      );
    });

    test('corruption outranks discontinuity, being the more specific', () {
      expect(
        classify(corrupted: 1, discontinuity: 1),
        PlaybackSmoothness.sourceCorrupt,
      );
    });
  });

  group('refusing to answer', () {
    test('a backend with no counters says nothing', () {
      expect(classify(statsAvailable: false), PlaybackSmoothness.unknown);
    });

    test('too few pictures to divide by says nothing', () {
      expect(
        classify(displayed: 10, lost: 2, decoded: 12),
        PlaybackSmoothness.unknown,
      );
    });

    test('a window that has not run yet says nothing', () {
      expect(
        classify(measuredFor: Duration.zero),
        PlaybackSmoothness.unknown,
      );
    });
  });

  group('the line that reaches a bug report', () {
    test('names the side at fault and what to do about it', () {
      final decoder = smoothnessReport(
        PlaybackSmoothness.decoderBehind,
        displayed: 200,
        lost: 40,
        corrupted: 0,
        discontinuity: 0,
      );
      final source = smoothnessReport(
        PlaybackSmoothness.sourceCorrupt,
        displayed: 200,
        lost: 40,
        corrupted: 12,
        discontinuity: 0,
      );

      expect(decoder, contains('lower'));
      expect(source, contains('another source'));
      expect(
        source,
        contains('quality will not help'),
        reason: 'the wrong fix is the one a viewer will reach for first',
      );
      // The numbers travel with the verdict, so a report can be checked.
      expect(decoder, contains('displayed=200'));
      expect(decoder, contains('lost=40'));
    });
  });
}
