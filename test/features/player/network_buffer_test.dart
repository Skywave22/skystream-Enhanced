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

    // Nothing chosen, so this device's default applies. The harness reports
    // no device profile, which resolves to the standard tier.
    expect(
      options,
      contains(
        '--prefetch-buffer-size=${defaultNetworkBufferMb(DeviceTier.standard) * 1024}',
      ),
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

  group('what a device starts with', () {
    test('more memory means a larger buffer, and never the reverse', () {
      final low = defaultNetworkBufferMb(DeviceTier.low);
      final standard = defaultNetworkBufferMb(DeviceTier.standard);
      final high = defaultNetworkBufferMb(DeviceTier.high);

      expect(low, lessThan(standard));
      expect(standard, lessThan(high));
      expect(high, 256, reason: 'a desktop can spare it');
    });

    test('every default is one of the sizes actually on offer', () {
      // Otherwise the dialog opens with nothing selected.
      for (final tier in DeviceTier.values) {
        expect(
          kNetworkBufferChoicesMb,
          contains(defaultNetworkBufferMb(tier)),
          reason: 'no row would be ticked on $tier',
        );
      }
    });

    test('512 MB is offered but is nobody default', () {
      // Offered because a desktop owner may want it; not a default, because
      // the buffer is resident and competes with the decoder.
      expect(kNetworkBufferChoicesMb, contains(512));
      expect(
        DeviceTier.values.map(defaultNetworkBufferMb),
        isNot(contains(512)),
      );
    });

    test('a choice beats the device, whichever way it goes', () {
      expect(resolveNetworkBufferMb(32, DeviceTier.high), 32);
      expect(resolveNetworkBufferMb(512, DeviceTier.low), 512);
    });

    test('no choice falls to the device', () {
      expect(
        resolveNetworkBufferMb(null, DeviceTier.high),
        defaultNetworkBufferMb(DeviceTier.high),
      );
    });
  });
}
