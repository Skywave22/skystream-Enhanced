import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_screen.dart'
    show kNetworkCachingMs;

import 'fake_vlc_engine.dart';
import 'vlc_screen_harness.dart';

/// `--network-caching` is output latency, and it is the delay on a track switch.
///
/// A stream selected mid-playback has to accumulate the whole caching interval
/// before it emits anything, while the picture - whose buffer is already full -
/// carries on. So the viewer sees video with no audio for exactly one interval.
/// This was measured at 60 seconds when the value was fed from a buffer-depth
/// setting in minutes, and a seek hid it, because a seek refills every stream
/// at once.
///
/// The number is therefore a user-visible latency budget, not a tuning knob,
/// and these tests exist to stop it drifting back up.
void main() {
  late FakeVlcEngine engine;

  setUp(() {
    engine = FakeVlcEngine();
    installEngineMocks(engine: engine);
  });
  tearDown(removeEngineMocks);

  /// The instance options libVLC was actually created with.
  List<String> createdOptions() {
    final create = engine.callsTo('create').single;
    final arguments = create.arguments as Map<Object?, Object?>;
    return (arguments['options'] as List<Object?>).cast<String>();
  }

  test('the caching interval stays inside a tolerable switch delay', () {
    // The bound is the point of the test. Anything above a few seconds is felt
    // directly as dead audio after a track change; 60000 was the shipped value
    // and produced a full minute of silence.
    expect(kNetworkCachingMs, lessThanOrEqualTo(5000));
    expect(kNetworkCachingMs, greaterThanOrEqualTo(1000));
  });

  testWidgets('libVLC is created with the bounded caching interval', variant: texturePlatform, (
    tester,
  ) async {
    await pumpPlayer(tester);
    await settle(tester);

    expect(createdOptions(), contains('--network-caching=$kNetworkCachingMs'));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('no setting reaches the caching interval', variant: texturePlatform, (
    tester,
  ) async {
    // A settings row used to offer 1 to 20 minutes of buffer depth and feed it
    // here, clamped onto the same 60000. The control did nothing except set
    // the length of the silence, and libVLC 3 has no read-ahead-in-seconds
    // option for a replacement to drive.
    await pumpPlayer(tester);
    await settle(tester);

    final caching = createdOptions()
        .where((o) => o.startsWith('--network-caching='))
        .toList();

    expect(caching, hasLength(1));
    expect(
      caching.single,
      isNot('--network-caching=60000'),
      reason: 'A buffer depth in minutes must not become a minute of latency.',
    );

    await tester.pumpWidget(const SizedBox());
  });
}
