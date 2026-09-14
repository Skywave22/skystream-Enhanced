import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/features/player/domain/playback_recovery.dart';

void main() {
  group('stallActionFor', () {
    StallAction at(
      int seconds, {
      bool hadFrames = true,
      StallAction last = StallAction.none,
      Duration? recoverAfter,
    }) => stallActionFor(
      stalledFor: Duration(seconds: seconds),
      hadFrames: hadFrames,
      lastAction: last,
      recoverAfter: recoverAfter ?? kStallRecoverAfter,
    );

    test('healthy playback asks for nothing', () {
      expect(at(0), StallAction.none);
      expect(at(3), StallAction.none);
      expect(at(9), StallAction.none);
    });

    test('a source that was playing gets nudged first', () {
      expect(at(10), StallAction.nudge);
      expect(at(20), StallAction.nudge);
    });

    // The whole point of lastAction: the caller ticks once a second, so
    // without it a single stall would re-issue the same seek 15 times.
    test('each rung fires once per stall window', () {
      expect(at(12, last: StallAction.nudge), StallAction.none);
      expect(at(30, last: StallAction.recover), StallAction.none);
    });

    test('a nudge that did not help escalates to recovery', () {
      expect(at(25, last: StallAction.nudge), StallAction.recover);
    });

    // A device that slept through the ladder must not spend another 25
    // seconds walking it.
    test('a long freeze escalates straight past the nudge', () {
      expect(at(600), StallAction.recover);
    });

    group('before the first frame', () {
      test('there is nothing to nudge', () {
        expect(at(10, hadFrames: false), StallAction.none);
        expect(at(24, hadFrames: false), StallAction.none);
      });

      test('the deadline still abandons the source', () {
        expect(at(25, hadFrames: false), StallAction.recover);
      });

      test('a torrent gets minutes to seed, not seconds', () {
        expect(
          at(60, hadFrames: false, recoverAfter: kTorrentStallRecoverAfter),
          StallAction.none,
        );
        expect(
          at(181, hadFrames: false, recoverAfter: kTorrentStallRecoverAfter),
          StallAction.recover,
        );
      });
    });
  });

  group('nextFailoverIndex', () {
    test('walks forward from the current candidate', () {
      expect(nextFailoverIndex(from: 0, total: 3, tried: {0}), 1);
      expect(nextFailoverIndex(from: 1, total: 3, tried: {0, 1}), 2);
    });

    // The bug this exists for: _start opens the resolver's pick, which is
    // routinely not zero, so a forward-only walk can never reach 0 or 1.
    test('wraps past the end to the candidates before the first pick', () {
      expect(nextFailoverIndex(from: 2, total: 3, tried: {2}), 0);
      expect(nextFailoverIndex(from: 0, total: 3, tried: {2, 0}), 1);
    });

    test('skips candidates already tried', () {
      expect(nextFailoverIndex(from: 1, total: 5, tried: {1, 2, 3}), 4);
    });

    test('gives up once every candidate has had a turn', () {
      expect(nextFailoverIndex(from: 1, total: 3, tried: {0, 1, 2}), isNull);
      expect(nextFailoverIndex(from: 0, total: 1, tried: {0}), isNull);
    });

    test('visits every candidate exactly once and then stops', () {
      const total = 4;
      final tried = <int>{2}; // the resolver's pick, already open
      var current = 2;
      final walk = <int>[];
      while (true) {
        final next = nextFailoverIndex(
          from: current,
          total: total,
          tried: tried,
        );
        if (next == null) break;
        walk.add(next);
        tried.add(next);
        current = next;
      }
      expect(walk, <int>[3, 0, 1]);
    });

    test('an empty candidate list has no next', () {
      expect(
        nextFailoverIndex(from: 0, total: 0, tried: const <int>{}),
        isNull,
      );
    });
  });

  /// The signal that answers the one question an advancing position cannot:
  /// whether anything is actually on the screen.
  ///
  /// The failure it exists for is invisible to every other watchdog. Audio
  /// drives libVLC's clock, so a 2016 television box software-decoding a 4K
  /// HEVC rendition reports a perfect position, `playing`, and a decoded video
  /// size, while the viewer watches two frames a second.
  group('videoHealthFor', () {
    VideoHealth read({
      bool available = true,
      bool video = true,
      int seconds = 10,
      required int displayed,
      required int lost,
    }) => videoHealthFor(
      statsAvailable: available,
      hasVideoTrack: video,
      measuredFor: Duration(seconds: seconds),
      displayed: displayed,
      lost: lost,
    );

    test('ordinary playback is healthy', () {
      // Ten seconds at 24 fps with the odd frame missed.
      expect(read(displayed: 240, lost: 3), VideoHealth.ok);
    });

    test('a clock that advances over no picture at all is absent', () {
      expect(read(displayed: 0, lost: 0), VideoHealth.absent);
      // A vout that opened, produced nothing, and is dropping everything it
      // decodes is the same failure wearing different numbers.
      expect(read(displayed: 0, lost: 900), VideoHealth.absent);
    });

    test('a decoder throwing most of its work away is overwhelmed', () {
      // The slideshow: sixteen pictures shown in ten seconds against a flood
      // dropped for arriving late.
      expect(read(displayed: 16, lost: 220), VideoHealth.overwhelmed);
    });

    // The whole reason the caller keeps a baseline rather than reading libVLC's
    // cumulative totals: a device that dropped frames while the buffer filled
    // and then settled must not be convicted on the first ten seconds forever.
    test('a busy patch under the share is not a verdict', () {
      expect(read(displayed: 200, lost: 40), VideoHealth.ok);
    });

    test('a window too short to have seen anything convicts nobody', () {
      expect(read(seconds: 7, displayed: 0, lost: 0), VideoHealth.ok);
      expect(read(seconds: 7, displayed: 4, lost: 400), VideoHealth.ok);
    });

    // A handful of pictures either way is noise, and the ratio over a handful
    // is meaningless. Absence is still absence.
    test('a ratio needs a sample behind it', () {
      expect(read(displayed: 8, lost: 8), VideoHealth.ok);
      expect(read(displayed: 20, lost: 40), VideoHealth.overwhelmed);
    });

    // Every backend implements getMediaStats and some answer nothing. Zeroes
    // from an engine that said it has no numbers are not evidence of anything,
    // and reading them as absence would fail every source over on the spot.
    test('an engine with no numbers is never convicted', () {
      expect(read(available: false, displayed: 0, lost: 0), VideoHealth.ok);
    });

    test('audio-only media has no picture to miss', () {
      expect(read(video: false, displayed: 0, lost: 0), VideoHealth.ok);
    });
  });

  /// The cap that stops the weakest device in the support window being handed
  /// the rendition it cannot decode in the first place.
  group('adaptiveMaxHeightFor', () {
    int cap({
      DeviceTier tier = DeviceTier.standard,
      int panel = 0,
      bool hardware = true,
    }) => adaptiveMaxHeightFor(
      tier: tier,
      panelHeightPx: panel,
      hardwareDecode: hardware,
    );

    // The headline case, and the one that has to hold: two devices behind the
    // same 4K panel, and only the one that can be shown to cope is offered the
    // top rung.
    test('the top rung is for devices known to manage it', () {
      expect(cap(tier: DeviceTier.high, panel: 2160), 2160);
      expect(cap(tier: DeviceTier.standard, panel: 2160), 1080);
      expect(cap(tier: DeviceTier.low, panel: 2160), 1080);
    });

    // Nothing Flutter can reach reports which MediaCodec profiles the SoC
    // implements, so an unresolved device profile is the common case on a cold
    // deep link. It has to read as the weak device, not the capable one.
    test('an unknown device is treated as the weak one', () {
      expect(cap(tier: DeviceTier.standard), 1080);
    });

    test('nobody is asked for more than the panel can show', () {
      expect(cap(tier: DeviceTier.high, panel: 1080), 1080);
      // A 1080p television at the density Android TV reports: 1920x1080
      // physical, and the shorter side is what a rendition height means.
      expect(cap(tier: DeviceTier.high, panel: 1080), 1080);
      // Rounded up, never down: a 900-line panel takes the 1080 rung rather
      // than being handed something smaller than itself to upscale.
      expect(cap(tier: DeviceTier.high, panel: 900), 1080);
    });

    // A desktop window is resized, maximised and full-screened mid-playback,
    // so its height when the engine is built is not a ceiling on anything.
    // Zero is how the caller says so.
    test('no panel measurement leaves the tier in charge', () {
      expect(cap(tier: DeviceTier.high, panel: 0), 2160);
    });

    test('software decode is nobody\'s capable class', () {
      expect(cap(tier: DeviceTier.high, panel: 2160, hardware: false), 1080);
      expect(cap(tier: DeviceTier.low, panel: 2160, hardware: false), 720);
    });

    test('never below the floor', () {
      expect(cap(tier: DeviceTier.low, panel: 240, hardware: false), 720);
      expect(cap(tier: DeviceTier.high, panel: 360), 720);
    });
  });

  /// What the cap above has to be told, and the reason it is not the switch
  /// on the settings screen.
  group('hardwareDecodeAvailable', () {
    bool on(TargetPlatform platform, {bool preference = true}) =>
        hardwareDecodeAvailable(platform: platform, preference: preference);

    // The one platform the option reaches a decoder on, so the one platform
    // where the answer moves with it.
    test('Android is the switch', () {
      expect(on(TargetPlatform.android), isTrue);
      expect(on(TargetPlatform.android, preference: false), isFalse);
    });

    // VideoToolbox is its own decoder module, not an avcodec accelerator, so
    // turning the switch off costs a Mac or an Apple TV nothing - and must
    // not cost it rungs either.
    test('Darwin decodes in hardware whichever way the switch is set', () {
      expect(on(TargetPlatform.macOS, preference: false), isTrue);
      expect(on(TargetPlatform.iOS, preference: false), isTrue);
    });

    // vmem pins avcodec-hw to none and there is no hardware decoder outside
    // avcodec, so the default-on switch would otherwise ask a pure software
    // decoder for 4K.
    test('the vmem platforms are software whichever way it is set', () {
      expect(on(TargetPlatform.windows), isFalse);
      expect(on(TargetPlatform.linux), isFalse);
    });
  });

  group('stepDownFrom', () {
    test('walks the rungs it was given', () {
      expect(stepDownFrom(2160), 1440);
      expect(stepDownFrom(1440), 1080);
      expect(stepDownFrom(1080), 720);
    });

    // Null is what stops a device that cannot decode anything reopening its
    // media forever.
    test('the floor has nothing below it', () {
      expect(stepDownFrom(720), isNull);
      expect(stepDownFrom(480), isNull);
    });
  });
}
