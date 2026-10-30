import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/providers/device_memory.dart';
import 'package:skystream/features/player/domain/media_options.dart';
import 'package:skystream/features/player/domain/network_buffer.dart';

BufferPlan plan(BufferMedia media) => bufferPlanFor(
  media: media,
  memory: const DeviceMemory(totalMb: 8192, freeMb: 4096),
  fallbackRamMb: 4096,
  metered: false,
  label: '1080p',
  maxHeight: 1080,
);

void main() {
  group('each media', () {
    test(
      'starts on 1 s on demand, 1.5 s live, and never names live-caching',
      () {
        final vod = playbackMediaOptions(
          live: false,
          plan: plan(BufferMedia.httpFile),
        );
        final live = playbackMediaOptions(
          live: true,
          plan: plan(BufferMedia.live),
        );

        expect(vod.where((o) => o.startsWith(':network-caching')), [
          ':network-caching=1000',
        ]);
        expect(live.where((o) => o.startsWith(':network-caching')), [
          ':network-caching=1500',
        ]);
        expect(
          [...vod, ...live].where((o) => o.contains('live-caching')),
          isEmpty,
          reason: 'live-caching only applies to capture devices',
        );
      },
    );

    test('live plays 8 s behind the edge; on demand has no delay', () {
      expect(
        playbackMediaOptions(live: true, plan: plan(BufferMedia.live)),
        contains(':adaptive-livedelay=$kLiveDelayMs'),
      );
      expect(kLiveDelayMs, 8000);
      expect(
        playbackMediaOptions(
          live: false,
          plan: plan(BufferMedia.adaptive),
        ).where((o) => o.contains('livedelay')),
        isEmpty,
      );
    });

    test("a file's read-ahead and an HLS buffer come from the plan", () {
      expect(
        playbackMediaOptions(live: false, plan: plan(BufferMedia.httpFile)),
        contains(':prefetch-buffer-size=${172 * 1024}'),
      );
      final hls = playbackMediaOptions(
        live: false,
        plan: plan(BufferMedia.adaptive),
      );
      expect(hls, contains(':adaptive-maxbuffer=180000'));
      expect(hls.where((o) => o.startsWith(':prefetch')), isEmpty);
    });

    test('live and local media leave the buffer to libVLC', () {
      for (final media in [BufferMedia.live, BufferMedia.local]) {
        expect(
          playbackMediaOptions(
            live: media == BufferMedia.live,
            plan: plan(media),
          ).where(
            (o) =>
                o.startsWith(':prefetch') ||
                o.startsWith(':adaptive-maxbuffer'),
          ),
          isEmpty,
        );
      }
    });

    test('a Quality pick plays its height exactly; Auto follows the link', () {
      final picked = playbackMediaOptions(
        live: false,
        plan: plan(BufferMedia.adaptive),
        renditionCap: 480,
        qualityPicked: true,
      );
      expect(
        picked,
        containsAll([':adaptive-maxheight=480', ':adaptive-logic=highest']),
      );

      final auto = playbackMediaOptions(
        live: false,
        plan: plan(BufferMedia.adaptive),
      );
      expect(auto.where((o) => o.startsWith(':adaptive-logic')), isEmpty);
    });

    test('a sound in a file of its own rides with the video', () {
      final options = playbackMediaOptions(
        live: false,
        plan: plan(BufferMedia.httpFile),
        audioSlave: 'http://127.0.0.1:8080/audio',
      );
      expect(options, contains(':input-slave=http://127.0.0.1:8080/audio'));
      expect(
        playbackMediaOptions(
          live: false,
          plan: plan(BufferMedia.httpFile),
        ).where((o) => o.startsWith(':input-slave')),
        isEmpty,
        reason: 'a stream with its own sound names no second input',
      );
    });

    test(
      'software decoding asks for every codec, and the language rides last',
      () {
        final options = playbackMediaOptions(
          live: false,
          plan: plan(BufferMedia.httpFile),
          softwareDecode: true,
          languageOption: ':audio-language=kn',
        );
        expect(options, contains(':codec=all'));
        expect(options.last, ':audio-language=kn');
      },
    );
  });

  test('hardware off decodes in software on Android only', () {
    bool soft(TargetPlatform platform, bool hardware) =>
        softwareDecodeFor(platform: platform, hardwareDecoding: hardware);
    expect(soft(TargetPlatform.android, false), isTrue);
    expect(soft(TargetPlatform.android, true), isFalse);
    expect(soft(TargetPlatform.macOS, false), isFalse);
    expect(soft(TargetPlatform.iOS, false), isFalse);
    expect(soft(TargetPlatform.windows, false), isFalse);
  });

  test("the player's own options, by platform", () {
    expect(playerInstanceOptions(TargetPlatform.android), [
      '--aout=android_audiotrack,opensles',
    ]);
    expect(playerInstanceOptions(TargetPlatform.windows), ['--swscale-mode=0']);
    expect(playerInstanceOptions(TargetPlatform.linux), ['--swscale-mode=0']);
    expect(playerInstanceOptions(TargetPlatform.macOS), isEmpty);
    expect(playerInstanceOptions(TargetPlatform.iOS), isEmpty);
  });

  test('a DASH manifest, directly or through the local proxy', () {
    expect(looksLikeDash(Uri.parse('https://cdn.test/a/manifest.mpd')), isTrue);
    expect(
      looksLikeDash(
        Uri.parse(
          'http://127.0.0.1:8080/proxy?url=https%3A%2F%2Fcdn.test%2Fm.mpd',
        ),
      ),
      isTrue,
    );
    expect(looksLikeDash(Uri.parse('https://cdn.test/a.mp4')), isFalse);
  });
}
