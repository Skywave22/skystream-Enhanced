import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/widgets/player_stream_widgets.dart';

import 'fake_vlc_engine.dart';
import 'vlc_screen_harness.dart';

/// The seek bar's buffered band, end to end on the real screen.
///
/// The band itself was already drawn; what it never had was a number, because
/// libVLC 3 publishes no buffered range and its buffering percentage sits at
/// 100 through healthy playback. The figure is derived from the byte counters
/// on the stats sample the video-health watchdog already takes, so these tests
/// drive real snapshots and read what the scrubber was handed.
void main() {
  late FakeVlcEngine engine;

  setUp(() {
    engine = FakeVlcEngine();
    installEngineMocks(engine: engine);
  });
  tearDown(removeEngineMocks);

  /// What the scrubber is currently told to shade.
  double bandRatio(WidgetTester tester) => tester
      .widget<PlayerScrubber>(find.byType(PlayerScrubber, skipOffstage: false))
      .bufferRatio;

  /// A stats reading with the counters the estimate reads.
  void stats({required int read, required int demux}) {
    engine.mediaStats = <String, Object?>{
      'available': true,
      'displayedPictures': 100,
      'lostPictures': 0,
      'readBytes': read,
      'demuxReadBytes': demux,
    };
  }

  testWidgets('nothing is shaded before there is anything to say', variant: texturePlatform, (
    tester,
  ) async {
    await pumpPlayer(tester);
    await sendEvent(tester, engine.event(<String, Object?>{'duration': 600000}));
    await settle(tester);

    expect(bandRatio(tester), 0);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('two samples give the band a width', variant: texturePlatform, (
    tester,
  ) async {
    await pumpPlayer(tester);

    // A ten-minute film, one minute in.
    Future<void> tick(int positionMs) => sendEvent(
      tester,
      engine.event(<String, Object?>{
        'duration': 600000,
        'position': positionMs,
      }),
    );

    await tick(60000);
    await settle(tester);

    // First sample is the datum - a rate needs two readings, so the band
    // stays empty here however inviting the numbers look.
    stats(read: 11000000, demux: 10000000);
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(bandRatio(tester), 0, reason: 'one reading is not a rate');

    // Second sample: 1 MB/s consumed, 5 MB fetched ahead - five seconds. One
    // minute in, that is 65s of a 600s film.
    stats(read: 16000000, demux: 11000000);
    await tick(61000);
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);

    final ratio = bandRatio(tester);
    expect(ratio, greaterThan(0), reason: 'the band should have a width now');
    expect(ratio, closeTo(66 / 600, 0.02));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the band empties rather than freezing when the estimate goes', variant: texturePlatform, (
    tester,
  ) async {
    await pumpPlayer(tester);
    Future<void> tick(int positionMs) => sendEvent(
      tester,
      engine.event(<String, Object?>{
        'duration': 600000,
        'position': positionMs,
      }),
    );

    await tick(60000);
    await settle(tester);
    stats(read: 11000000, demux: 10000000);
    await tester.pump(const Duration(seconds: 1));
    await tick(61000);
    stats(read: 16000000, demux: 11000000);
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(bandRatio(tester), greaterThan(0));

    // The demuxer stops consuming: stalled, or the counters were reset by a
    // reopen. A band that kept its old width would be claiming a buffer that
    // is not there, which is the one thing worse than showing nothing.
    // Two ticks: one to take the sample, one for the round trip that answers
    // it. The sampler refuses to overlap requests, so a single pump can land
    // while the previous one is still in flight.
    for (var i = 0; i < 2; i++) {
      await tick(62000 + i * 1000);
      stats(read: 16000000, demux: 11000000);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
    }

    expect(bandRatio(tester), 0);

    await tester.pumpWidget(const SizedBox());
  });
}
