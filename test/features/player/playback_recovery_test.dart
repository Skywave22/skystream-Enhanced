import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clock/clock.dart';
import 'package:vlc_player/vlc_player.dart'
    show VlcAudioInterruption, VlcMediaStats, VlcPlaybackState;
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/features/player/domain/playback_recovery.dart';
import 'package:skystream/features/player/domain/stream_resolver.dart'
    show ProbeOutcome;

void main() {
  group('stallActionFor', () {
    StallAction at(
      int seconds, {
      bool hadFrames = true,
      StallAction last = StallAction.none,
      Duration? recoverAfter,
      bool arriving = false,
      bool afterSeek = false,
    }) => stallActionFor(
      stalledFor: Duration(seconds: seconds),
      hadFrames: hadFrames,
      lastAction: last,
      recoverAfter: recoverAfter ?? kStallRecoverAfter,
      arriving: arriving,
      afterSeek: afterSeek,
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

    // Bytes still arriving mean the source is refilling, not quiet: a 4K
    // remux needs its keyframe run-up and three seconds of buffer before it
    // plays again after a seek, and on an ordinary line that outlasts the
    // nudge. The nudge's fresh request threw the refill away and started it
    // over.
    group('while bytes are still arriving', () {
      test('there is no nudge', () {
        expect(at(10, arriving: true), StallAction.none);
        expect(at(24, arriving: true), StallAction.none);
      });

      test('and no recovery at the usual deadline', () {
        expect(at(25, arriving: true), StallAction.none);
        expect(at(59, arriving: true), StallAction.none);
      });

      test('but a trickle is still given up on in the end', () {
        expect(
          at(kStallRecoverWhileArrivingAfter.inSeconds, arriving: true),
          StallAction.recover,
        );
      });

      test('a longer deadline of its own still applies', () {
        expect(
          at(60, arriving: true, recoverAfter: kTorrentStallRecoverAfter),
          StallAction.none,
        );
        expect(
          at(181, arriving: true, recoverAfter: kTorrentStallRecoverAfter),
          StallAction.recover,
        );
      });

      test('once they stop, the ladder resumes where the clock is', () {
        expect(at(30), StallAction.recover);
        expect(at(12), StallAction.nudge);
      });
    });

    // A seek has a keyframe run-up and a fresh buffer to fetch before the
    // picture moves again, and while libVLC's input thread waits on that read
    // its byte counters do not move either - so a slow refill cannot be told
    // from a dead source by them, and gets time instead.
    group('after a seek', () {
      test('the nudge waits longer', () {
        expect(at(10, afterSeek: true), StallAction.none);
        expect(at(19, afterSeek: true), StallAction.none);
        expect(
          at(kStallNudgeAfterSeek.inSeconds, afterSeek: true),
          StallAction.nudge,
        );
      });

      test('and so does recovery', () {
        expect(
          at(25, afterSeek: true, last: StallAction.nudge),
          StallAction.none,
        );
        expect(
          at(
            kStallRecoverAfterSeek.inSeconds,
            afterSeek: true,
            last: StallAction.nudge,
          ),
          StallAction.recover,
        );
      });

      test('bytes arriving still hold off the nudge altogether', () {
        expect(at(30, afterSeek: true, arriving: true), StallAction.none);
      });
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

    // The reachability check already said these are dead, and a dead source
    // that hangs rather than erroring costs the full stall deadline.
    test('passes over candidates the check found unreachable', () {
      expect(
        nextFailoverIndex(from: 0, total: 4, tried: {0}, unreachable: {1, 2}),
        3,
      );
    });

    // Not dropped: a slow host or one that refuses the probe's requests reads
    // as unreachable and still streams, so it is the last resort, not nothing.
    test('reaches the unreachable ones once nothing else is left', () {
      expect(
        nextFailoverIndex(
          from: 3,
          total: 4,
          tried: {0, 3},
          unreachable: {1, 2},
        ),
        1,
      );
      expect(
        nextFailoverIndex(
          from: 1,
          total: 4,
          tried: {0, 1, 3},
          unreachable: {1, 2},
        ),
        2,
      );
    });

    test('an unreachable candidate that has been tried stays tried', () {
      expect(
        nextFailoverIndex(from: 0, total: 3, tried: {0, 1}, unreachable: {1}),
        2,
      );
      expect(
        nextFailoverIndex(
          from: 2,
          total: 3,
          tried: {0, 1, 2},
          unreachable: {1},
        ),
        isNull,
      );
    });

    // Failing over mid-film resumes where it stopped, and a source whose server
    // ignores byte ranges would start it again from the top.
    test('passes over candidates that cannot seek while there are others', () {
      expect(
        nextFailoverIndex(from: 0, total: 4, tried: {0}, cannotSeek: {1}),
        2,
      );
    });

    test('takes one that cannot seek before one the check found dead', () {
      expect(
        nextFailoverIndex(
          from: 0,
          total: 4,
          tried: {0, 3},
          unreachable: {1},
          cannotSeek: {2},
        ),
        2,
      );
    });
  });

  // Resuming on a source whose server ignores byte ranges plays the film from
  // the top: libVLC cannot jump into it, so the viewer's place is lost.
  group('resumeSourceIndex', () {
    test('keeps the chosen source when it can seek, or nobody knows', () {
      expect(
        resumeSourceIndex(
          preferred: 0,
          total: 3,
          probes: {0: ProbeOutcome.healthy},
        ),
        0,
      );
      expect(
        resumeSourceIndex(
          preferred: 1,
          total: 3,
          probes: const <int, ProbeOutcome>{},
        ),
        1,
      );
    });

    test('moves off one that cannot seek to one found able to', () {
      expect(
        resumeSourceIndex(
          preferred: 0,
          total: 4,
          probes: {
            0: ProbeOutcome.unseekable,
            1: ProbeOutcome.unhealthy,
            2: ProbeOutcome.notVideo,
            3: ProbeOutcome.healthy,
          },
        ),
        3,
      );
    });

    test('stays when none able to seek has been found', () {
      expect(
        resumeSourceIndex(
          preferred: 0,
          total: 3,
          probes: {0: ProbeOutcome.unseekable, 1: ProbeOutcome.trying},
        ),
        0,
      );
    });
  });

  // Where to go when a source being opened turns out unreachable: back to one
  // the check has already vouched for, rather than on down the list.
  group('firstReachableIndex', () {
    test('is the first candidate the check found reachable', () {
      expect(
        firstReachableIndex(
          total: 4,
          probes: {1: ProbeOutcome.healthy, 2: ProbeOutcome.healthy},
          failed: const <int>{},
          except: 3,
        ),
        1,
      );
    });

    test('passes over the one being abandoned and any that failed', () {
      expect(
        firstReachableIndex(
          total: 4,
          probes: {
            0: ProbeOutcome.healthy,
            1: ProbeOutcome.healthy,
            2: ProbeOutcome.healthy,
          },
          failed: const <int>{0},
          except: 1,
        ),
        2,
      );
    });

    test('prefers one that can seek, and still counts one that cannot', () {
      expect(
        firstReachableIndex(
          total: 3,
          probes: {0: ProbeOutcome.unseekable, 1: ProbeOutcome.healthy},
          failed: const <int>{},
          except: 2,
        ),
        1,
      );
      expect(
        firstReachableIndex(
          total: 3,
          probes: {0: ProbeOutcome.unseekable, 1: ProbeOutcome.notVideo},
          failed: const <int>{},
          except: 2,
        ),
        0,
      );
    });

    // A probe still out, or one that got no answer, has vouched for nothing.
    test('is nothing when no candidate has been vouched for', () {
      expect(
        firstReachableIndex(
          total: 3,
          probes: {0: ProbeOutcome.trying, 1: ProbeOutcome.unhealthy},
          failed: const <int>{},
          except: 2,
        ),
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

  group('renditionCapFor', () {
    test('Auto is the device rung under no preference', () {
      expect(renditionCapFor(deviceCap: 1080), 1080);
    });

    test('Auto is the preference where it is below the device', () {
      expect(renditionCapFor(deviceCap: 2160, preferenceHeight: 1080), 1080);
      expect(renditionCapFor(deviceCap: 1080, preferenceHeight: 480), 480);
    });

    test('a preference above the device does not raise Auto', () {
      expect(renditionCapFor(deviceCap: 1080, preferenceHeight: 2160), 1080);
    });

    test('a pick is taken as it is, above the device too', () {
      expect(
        renditionCapFor(deviceCap: 1080, pick: 2160, preferenceHeight: 720),
        2160,
      );
      expect(
        renditionCapFor(deviceCap: 1080, pick: 360, preferenceHeight: 1080),
        360,
      );
    });
  });

  group('the software retry', () {
    test('is for Android with hardware decoding on, and only once', () {
      bool retry(
        TargetPlatform platform, {
        bool hw = true,
        bool done = false,
      }) => shouldRetryInSoftware(
        platform: platform,
        hardwareDecoding: hw,
        alreadySoftware: done,
        lostInWindow: 0,
      );
      expect(retry(TargetPlatform.android), isTrue);
      expect(retry(TargetPlatform.android, done: true), isFalse);
      expect(retry(TargetPlatform.android, hw: false), isFalse);
      for (final platform in [
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        expect(retry(platform), isFalse, reason: '$platform');
      }
    });

    // The Android TV emulator, P1 Part 1's matrix: "pictures are decoded but
    // never shown" (displayed 0, lost 8) after a live reopen. The decoder made
    // those pictures and the video output dropped them, the surface stall the
    // spec gives Part 2. Software decoding brings no picture back, and holds
    // the rest of the viewing to the CPU's lower rendition.
    test('is not for pictures the output dropped: the decoder made them', () {
      expect(
        shouldRetryInSoftware(
          platform: TargetPlatform.android,
          hardwareDecoding: true,
          alreadySoftware: false,
          lostInWindow: 8,
        ),
        isFalse,
      );
    });

    test('caps the rendition where a CPU keeps up, and never raises it', () {
      expect(
        softwareRetryCap(
          tier: DeviceTier.high,
          panelHeightPx: 2160,
          currentCap: 2160,
        ),
        1080,
      );
      expect(
        softwareRetryCap(
          tier: DeviceTier.low,
          panelHeightPx: 1080,
          currentCap: 1080,
        ),
        720,
      );
      expect(
        softwareRetryCap(
          tier: DeviceTier.standard,
          panelHeightPx: 1080,
          currentCap: 720,
        ),
        720,
      );
    });
  });

  group('the watchdog\'s clock (spec 2: wall-clock time)', () {
    late DateTime now;
    late StallClock stall;

    void timed(String description, void Function() body) {
      test(description, () {
        now = DateTime.utc(2026, 10, 15, 20);
        withClock(Clock(() => now), () {
          stall = StallClock();
          body();
        });
      });
    }

    timed('a jump of 60 s counts as 60 s', () {
      stall.tick(const Duration(seconds: 12));
      now = now.add(const Duration(seconds: 60));

      expect(stall.tick(const Duration(seconds: 12)), isFalse);
      expect(stall.stalledFor, const Duration(seconds: 60));
    });

    timed('a clock that goes back adds nothing', () {
      stall.tick(const Duration(seconds: 12));
      now = now.subtract(const Duration(seconds: 30));

      stall.tick(const Duration(seconds: 12));
      expect(stall.stalledFor, Duration.zero);
    });

    timed('a clock jump while the position moves counts nothing', () {
      stall.tick(const Duration(seconds: 12));
      now = now.add(const Duration(seconds: 30));

      expect(stall.tick(const Duration(seconds: 13)), isTrue);
      expect(stall.stalledFor, Duration.zero);
    });

    timed('a restart counts from itself: ten minutes paused is no stall', () {
      stall.tick(const Duration(seconds: 12));
      // Paused: the watchdog restarts the count on every tick, the last one
      // just before play resumes.
      now = now.add(const Duration(minutes: 10));
      stall.restart();
      now = now.add(const Duration(milliseconds: 600));

      stall.tick(const Duration(seconds: 12));
      expect(stall.stalledFor, const Duration(milliseconds: 600));
    });

    timed('a stall adds up tick by tick, and a move starts it again', () {
      stall.tick(const Duration(seconds: 12));
      for (var i = 0; i < 9; i++) {
        now = now.add(const Duration(seconds: 1));
        stall.tick(const Duration(seconds: 12));
      }
      expect(stall.stalledFor, const Duration(seconds: 9));

      now = now.add(const Duration(seconds: 1));
      stall.tick(const Duration(seconds: 13));
      expect(stall.stalledFor, Duration.zero);
    });

    test(
      'a frozen picture noticed 60 s late recovers at once, past the nudge',
      () {
        expect(
          stallActionFor(
            stalledFor: const Duration(seconds: 60),
            hadFrames: true,
            lastAction: StallAction.none,
          ),
          StallAction.recover,
        );
      },
    );
  });

  group('HLS and DASH stalls', () {
    StallAction adaptive(int seconds, {bool afterSeek = false}) =>
        stallActionFor(
          stalledFor: Duration(seconds: seconds),
          hadFrames: true,
          lastAction: StallAction.none,
          afterSeek: afterSeek,
          adaptive: true,
        );

    test('get no nudge, and reach recovery at 25 s, or 40 s after a seek', () {
      expect(adaptive(10), StallAction.none);
      expect(adaptive(24), StallAction.none);
      expect(adaptive(25), StallAction.recover);
      expect(adaptive(25, afterSeek: true), StallAction.none);
      expect(adaptive(40, afterSeek: true), StallAction.recover);
    });

    test('bytes still arriving are the demuxer\'s for HLS and DASH, and the '
        'access\'s for files', () {
      const stats = VlcMediaStats(
        isAvailable: true,
        readBytes: 1200,
        demuxReadBytes: 8000000,
      );

      expect(arrivalBytesOf(stats, adaptive: true), 8000000);
      expect(arrivalBytesOf(stats, adaptive: false), 1200);
    });
  });

  group('a starved video', () {
    late StarvedVideoWatch watch;
    setUp(() => watch = StarvedVideoWatch());

    Duration? at(
      int seconds,
      int decoded, {
      bool running = true,
      Duration? remaining,
    }) => watch.sample(
      decodedVideo: decoded,
      position: Duration(seconds: seconds),
      running: running,
      remaining: remaining,
    );

    test('the clock running 3 s with no new picture is starved, at the last '
        'picture', () {
      expect(at(8, 192), isNull);
      expect(at(9, 216), isNull);
      expect(at(10, 240), isNull);
      expect(at(11, 240), isNull);
      expect(at(12, 240), isNull);
      expect(at(13, 240), const Duration(seconds: 10));
    });

    test('new pictures keep it fed', () {
      for (var s = 10; s < 30; s++) {
        expect(at(s, 240 + (s - 10) * 24), isNull);
      }
    });

    test('a slideshow is never starved: a new picture every 5 s', () {
      for (var s = 10; s < 40; s++) {
        expect(at(s, 100 + (s - 10) ~/ 5), isNull, reason: '$s s');
      }
    });

    test('a backend whose counter never moves is never starved', () {
      for (var s = 10; s < 30; s++) {
        expect(at(s, 0), isNull);
      }
    });

    test('a paused player is never starved', () {
      at(9, 216);
      at(10, 240);
      for (var s = 11; s < 20; s++) {
        expect(at(s, 240, running: false), isNull);
      }
    });

    test('the last 5 s are never starved', () {
      at(9, 216, remaining: const Duration(seconds: 9));
      at(10, 240, remaining: const Duration(seconds: 8));
      for (var s = 11; s < 20; s++) {
        expect(
          at(s, 240, remaining: Duration(seconds: 18 - s)),
          isNull,
          reason: '$s s',
        );
      }
    });

    test(
      'the trickle of a starving video\'s last pictures is no slideshow',
      () {
        // macOS, hostdown-2src (P1 Part 3): 50 pictures a second of playback,
        // then the last 2 over a second of sound, then none. Read across that
        // last gap alone, the rate was 1.95 a second, under the slideshow
        // floor, and the frozen picture was never noticed.
        Duration? ms(int position, int decoded) => watch.sample(
          decodedVideo: decoded,
          position: Duration(milliseconds: position),
          running: true,
        );
        for (final (position, decoded) in const [
          (18760, 949),
          (19735, 1001),
          (20768, 1041),
          (21768, 1091),
          (22759, 1143),
          (23785, 1145),
          (24731, 1145),
          (25736, 1145),
          (26757, 1145),
        ]) {
          expect(ms(position, decoded), isNull, reason: '$position');
        }
        expect(ms(27734, 1145), const Duration(milliseconds: 23785));
      },
    );

    test('a seek starts the count again from where it landed', () {
      at(9, 216);
      at(10, 240);
      expect(at(70, 240), isNull);
      expect(at(71, 240), isNull);
      expect(at(72, 240), isNull);
      expect(at(73, 240), const Duration(seconds: 70));
    });
  });

  group('the end', () {
    test('an end more than 2 s before the length is a false end; at the '
        'length it is the end; with no length it is a false end', () {
      const length = Duration(minutes: 10);

      expect(
        isFalseEnd(position: const Duration(minutes: 9), duration: length),
        isTrue,
      );
      expect(
        isFalseEnd(
          position: length - const Duration(milliseconds: 1500),
          duration: length,
        ),
        isFalse,
      );
      expect(
        isFalseEnd(
          position: const Duration(minutes: 9),
          duration: Duration.zero,
        ),
        isTrue,
      );
    });
  });

  group('a pause or stop nobody asked for (spec 2)', () {
    bool unasked({
      VlcPlaybackState state = VlcPlaybackState.paused,
      int requests = 3,
      int whenRunning = 3,
      VlcAudioInterruption interruption = VlcAudioInterruption.none,
      bool foreground = true,
    }) => isUnaskedStop(
      state: state,
      pauseRequests: requests,
      pauseRequestsWhenRunning: whenRunning,
      interruption: interruption,
      foreground: foreground,
    );

    test('a pause nobody asked for is a failure', () {
      expect(unasked(), isTrue);
    });

    test('a pause the viewer, the background policy or the app asked for is '
        'not', () {
      expect(unasked(requests: 4), isFalse);
    });

    test('a pause during an audio interruption is not', () {
      expect(
        unasked(interruption: VlcAudioInterruption.focusLostTransient),
        isFalse,
      );
      expect(unasked(interruption: VlcAudioInterruption.focusLost), isFalse);
    });

    test('a pause with the app away is not', () {
      expect(unasked(foreground: false), isFalse);
    });

    test('a stop the app made is not; a stop nobody asked for is', () {
      expect(unasked(state: VlcPlaybackState.stopped, requests: 4), isFalse);
      expect(unasked(state: VlcPlaybackState.stopped), isTrue);
    });

    test('playing, buffering or ended is never one', () {
      for (final state in [
        VlcPlaybackState.playing,
        VlcPlaybackState.buffering,
        VlcPlaybackState.ended,
      ]) {
        expect(unasked(state: state), isFalse, reason: state.name);
      }
    });
  });

  group('the first frame', () {
    late DateTime now;

    void timed(String description, void Function() body) {
      test(description, () {
        now = DateTime.utc(2026, 10, 15, 20);
        withClock(Clock(() => now), body);
      });
    }

    void pass(int seconds) => now = now.add(Duration(seconds: seconds));

    timed('no progress for 30 s gives up', () {
      final watch = FirstFrameWatch()
        ..sample(const OpeningSample(state: VlcPlaybackState.opening));
      pass(29);
      // The same reading again: nothing moved.
      expect(
        watch.sample(const OpeningSample(state: VlcPlaybackState.opening)),
        isFalse,
      );
      expect(watch.verdict, FirstFrameVerdict.wait);
      pass(1);
      expect(watch.verdict, FirstFrameVerdict.giveUp);
    });

    timed('progress restarts the 30 s: the prebuffer, bytes read or demuxed, '
        'pictures or audio decoded, the state, Android\'s start gate', () {
      for (final progress in const [
        OpeningSample(state: VlcPlaybackState.buffering),
        OpeningSample(prebuffer: 0.2),
        OpeningSample(readBytes: 4096),
        OpeningSample(demuxReadBytes: 4096),
        OpeningSample(decodedVideo: 1),
        OpeningSample(decodedAudio: 1),
        OpeningSample(startGated: true),
      ]) {
        final watch = FirstFrameWatch();
        pass(25);
        expect(watch.sample(progress), isTrue, reason: '$progress');
        pass(25);
        expect(watch.verdict, FirstFrameVerdict.wait, reason: '$progress');
        pass(5);
        expect(watch.verdict, FirstFrameVerdict.giveUp, reason: '$progress');
      }
    });

    timed('the same reading again is no progress', () {
      final watch = FirstFrameWatch();
      expect(watch.sample(const OpeningSample(readBytes: 4096)), isTrue);
      expect(watch.sample(const OpeningSample(readBytes: 4096)), isFalse);
    });

    timed('a start still progressing gives up at 60 s', () {
      final watch = FirstFrameWatch();
      for (var s = 1; s <= 59; s++) {
        pass(1);
        watch.sample(OpeningSample(readBytes: s * 1000));
      }
      expect(watch.verdict, FirstFrameVerdict.wait);
      pass(1);
      watch.sample(const OpeningSample(readBytes: 999999));
      expect(watch.verdict, FirstFrameVerdict.giveUp);
    });

    timed("the 60 s cap counts from the start gate's opening", () {
      // Android's gate holds the first video's play while libVLC builds its
      // font database (FORK.md 26), up to 60 s on a slow device: counted, the
      // cap gave a healthy source up as soon as it could start (P1 Part 3
      // review, finding 8).
      final watch = FirstFrameWatch();
      for (var s = 1; s <= 50; s++) {
        pass(1);
        watch.sample(const OpeningSample(startGated: true));
      }
      for (var s = 1; s <= 20; s++) {
        pass(1);
        watch.sample(OpeningSample(readBytes: s * 1000));
      }
      expect(watch.verdict, FirstFrameVerdict.wait, reason: '20 s since it');
      for (var s = 21; s <= 60; s++) {
        pass(1);
        watch.sample(OpeningSample(readBytes: s * 1000));
      }
      expect(watch.verdict, FirstFrameVerdict.giveUp, reason: '60 s since it');
    });

    timed('torrents keep 3 minutes from the open', () {
      final watch = FirstFrameWatch(torrent: true);
      pass(179);
      expect(watch.verdict, FirstFrameVerdict.wait);
      pass(1);
      expect(watch.verdict, FirstFrameVerdict.giveUp);
    });

    timed('a restart counts from now', () {
      final watch = FirstFrameWatch();
      pass(29);
      watch.restart();
      pass(29);
      expect(watch.verdict, FirstFrameVerdict.wait);
    });
  });
}
