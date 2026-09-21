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
  _torrentSplitTests();
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
      expect(
        high,
        512,
        reason:
            'anything with memory to spare, which is every desktop and any '
            'handset reporting 6 GB or more - the tier is a RAM verdict, not '
            'a platform one',
      );
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

    test('the largest size is offered but is nobody default', () {
      // Offered because someone with the memory may want it; never a default,
      // because the buffer is resident and competes with the decoder's own
      // picture pool - and the top of this range is not sized for the bottom
      // of the device range.
      final largest = kNetworkBufferChoicesMb.last;
      expect(largest, 1024);
      expect(
        DeviceTier.values.map(defaultNetworkBufferMb),
        isNot(contains(largest)),
      );
    });

    test('a choice beats the device, whichever way it goes', () {
      expect(resolveNetworkBufferMb(64, DeviceTier.high), 64);
      expect(resolveNetworkBufferMb(1024, DeviceTier.low), 1024);
    });

    test('no choice falls to the device', () {
      expect(
        resolveNetworkBufferMb(null, DeviceTier.high),
        defaultNetworkBufferMb(DeviceTier.high),
      );
    });
  });
}

/// The torrent cache's ahead/behind split.
///
/// TorrServer holds one cache and `readerReadAHead` is the share of it kept in
/// front of the read point. The remainder is the only backward buffer anywhere
/// in this player - libVLC 3's prefetch filter takes a size and decides the
/// rest itself - so this is where "a ten second step back should not
/// re-download" is answered.
void _torrentSplitTests() {
  group('torrentReadAheadPercent', () {
    /// How much of a cache is left behind the playhead at this split.
    double behindMb(int cacheMb) =>
        cacheMb * (100 - torrentReadAheadPercent(cacheMb)) / 100;

    test('a quarter of the cache is held behind the playhead', () {
      for (final cacheMb in kNetworkBufferChoicesMb) {
        final behind = behindMb(cacheMb);
        expect(
          behind,
          greaterThan(0),
          reason: '$cacheMb MB kept nothing behind the read point',
        );
        expect(
          behind,
          lessThanOrEqualTo(kMaxTorrentBehindMb.toDouble()),
          reason: 'the behind window is capped; the rest is what plays',
        );
      }
    });

    test('and it is enough for the step the seek buttons take', () {
      // A ten second step at 1080p is roughly 10 MB - 8 Mbit/s is 1 MB/s. The
      // 95 % this replaced left about 3 MB behind a 64 MB cache, so every
      // back-step of any size re-fetched pieces the reader had just released.
      for (final cacheMb in kNetworkBufferChoicesMb) {
        expect(
          behindMb(cacheMb),
          greaterThanOrEqualTo(8),
          reason: '$cacheMb MB leaves too little behind for a 10 s step back',
        );
      }
    });

    test('the cap stops a large cache spending all of it on history', () {
      // 512 MB at a flat quarter would be 128 MB of data already watched.
      expect(behindMb(512), lessThanOrEqualTo(kMaxTorrentBehindMb.toDouble()));
      expect(
        torrentReadAheadPercent(512),
        greaterThan(torrentReadAheadPercent(128)),
        reason: 'a bigger cache spends proportionally more of it ahead',
      );
    });

    test('read-ahead never drops low enough to starve playback', () {
      for (final cacheMb in <int>[1, 8, 32, 64, 128, 256, 512, 2048]) {
        expect(torrentReadAheadPercent(cacheMb), inInclusiveRange(60, 99));
      }
    });

    test('a nonsense cache falls back rather than dividing by zero', () {
      expect(torrentReadAheadPercent(0), 95);
      expect(torrentReadAheadPercent(-1), 95);
    });
  });
}
