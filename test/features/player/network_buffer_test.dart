import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/features/player/domain/network_buffer.dart';

import 'fake_vlc_engine.dart';
import 'vlc_screen_harness.dart';

/// Read-ahead, and why it is not the caching option.
///
/// `--network-caching` is output latency: every stream has to fill it before
/// it emits anything, so a large value there made a newly selected audio track
/// silent for exactly that long. `--prefetch-buffer-size` sits under the
/// demuxer instead and holds a window either side of the read point, so a
/// larger one costs memory and nothing else. It is what makes a seek land
/// without going back to the network, in either direction.
///
/// The prefetch filter scores 0 in libVLC, which means it is never selected on
/// its own - `--stream-filter=prefetch` has to name it, and the two options
/// only mean anything together.
void main() {
  late FakeVlcEngine engine;

  setUp(() {
    engine = FakeVlcEngine();
    installEngineMocks(engine: engine);
  });
  tearDown(removeEngineMocks);

  List<String> createdOptions() {
    final create = engine.callsTo('create').single;
    final arguments = create.arguments as Map<Object?, Object?>;
    return (arguments['options'] as List<Object?>).cast<String>();
  }

  group('the option pair', () {
    test('a buffer size names the filter as well', () {
      const config = VlcNetworkConfig(prefetchBufferKiB: 16384);

      expect(config.toOptions(), containsAll(<String>[
        '--stream-filter=prefetch',
        '--prefetch-buffer-size=16384',
      ]));
    });

    test('no buffer size means neither option, so libVLC keeps its own', () {
      const config = VlcNetworkConfig();

      expect(
        config.toOptions().where((o) => o.contains('prefetch')),
        isEmpty,
      );
    });
  });

  testWidgets('the player asks for the buffer in KiB', variant: texturePlatform, (
    tester,
  ) async {
    await pumpPlayer(tester);
    await settle(tester);

    final options = createdOptions();
    expect(options, contains('--stream-filter=prefetch'));

    // The default wish is three minutes. What that becomes in bytes depends
    // on the rendition and the device, so the assertion is the contract - a
    // real, capped, KiB figure - not a magic number.
    final size = options.firstWhere(
      (o) => o.startsWith('--prefetch-buffer-size='),
    );
    final kib = int.parse(size.split('=').last);
    expect(kib, greaterThanOrEqualTo(4));
    expect(
      kib,
      lessThanOrEqualTo(256 * 1024),
      reason: 'never past the largest ceiling any tier allows',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('read-ahead is not latency', variant: texturePlatform, (
    tester,
  ) async {
    // The two must not be confused again: a buffer measured in megabytes has
    // no business reaching the caching option, which is measured in
    // milliseconds and is felt on every track switch.
    await pumpPlayer(tester);
    await settle(tester);

    final options = createdOptions();
    final caching = options.firstWhere(
      (o) => o.startsWith('--network-caching='),
    );

    expect(caching, '--network-caching=3000');
    expect(
      options.where((o) => o.startsWith('--network-caching=')),
      hasLength(1),
      reason: 'the buffer setting must not add a second caching option',
    );

    await tester.pumpWidget(const SizedBox());
  });

  group('minutes into bytes', () {
    test('a wish is honoured when the device can afford it', () {
      // 1 minute of 720p is 5 Mbps / 8 * 60 = 37.5 MB, inside every ceiling.
      final kib = prefetchBufferKiBFor(
        minutes: 1,
        maxHeight: 720,
        tier: DeviceTier.high,
      );

      expect(kib, (5000000 ~/ 8) * 60 ~/ 1024);
    });

    test('a wish past what the device can hold is capped, not granted', () {
      // Three minutes of 4K is ~562 MB. A low-tier stick has 48 MB to give,
      // and granting the wish would be an OOM kill rather than a setting.
      final low = prefetchBufferKiBFor(
        minutes: 3,
        maxHeight: 2160,
        tier: DeviceTier.low,
      );
      final high = prefetchBufferKiBFor(
        minutes: 3,
        maxHeight: 2160,
        tier: DeviceTier.high,
      );

      expect(low, 48 * 1024);
      expect(high, 256 * 1024);
      expect(low, lessThan(high));
    });

    test('the label shows what was actually reserved', () {
      // The number beside "3 min" has to be the capped one, or the setting
      // promises memory it never took.
      expect(
        prefetchBufferMbFor(minutes: 3, maxHeight: 2160, tier: DeviceTier.low),
        48,
      );
    });

    test('never below libVLC\'s own floor for the option', () {
      expect(
        prefetchBufferKiBFor(minutes: 1, maxHeight: 360, tier: DeviceTier.low),
        greaterThanOrEqualTo(4),
      );
    });
  });
}
