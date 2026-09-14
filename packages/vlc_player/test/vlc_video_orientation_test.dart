import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart';

/// Which way up the picture is, and how each backend says so.
///
/// This is what decides whether a handset physically turns, so the cost of an
/// error is a device rotating the wrong way on the one video the viewer most
/// wants turned. The stored size cannot answer it - every phone camera records
/// landscape frames and writes a rotation beside them - so the answer is
/// assembled from two fields, and both halves are pinned here.
void main() {
  group('VlcVideoOrientation.swapsAxes', () {
    test('is libVLC ORIENT_IS_SWAP, exactly', () {
      // The four quarter turns exchange width and height; the four flips and
      // half turns do not. Spelled out one by one rather than derived, so a
      // change to the predicate has to disagree with a written-down truth
      // table instead of with a rearranged copy of itself.
      expect(VlcVideoOrientation.topLeft.swapsAxes, isFalse);
      expect(VlcVideoOrientation.topRight.swapsAxes, isFalse);
      expect(VlcVideoOrientation.bottomLeft.swapsAxes, isFalse);
      expect(VlcVideoOrientation.bottomRight.swapsAxes, isFalse);
      expect(VlcVideoOrientation.leftTop.swapsAxes, isTrue);
      expect(VlcVideoOrientation.leftBottom.swapsAxes, isTrue);
      expect(VlcVideoOrientation.rightTop.swapsAxes, isTrue);
      expect(VlcVideoOrientation.rightBottom.swapsAxes, isTrue);
    });

    test('does not inherit the bug in libVLC\'s own Android bindings', () {
      // VideoHelper.java tests `orientation == 5 || orientation == 6`, which
      // gets the two quarter turns right and silently misses both transposes.
      // If this ever starts matching that, a transposed clip goes back to
      // rotating the handset the wrong way.
      expect(VlcVideoOrientation.leftTop.swapsAxes, isTrue,
          reason: 'Transposed (4) swaps axes; libVLC\'s Android helper misses it.');
      expect(VlcVideoOrientation.rightBottom.swapsAxes, isTrue,
          reason: 'Anti-transposed (7) swaps axes; the same helper misses it.');
    });

    test('index order matches libvlc_video_orient_t, which is the wire format',
        () {
      // The native side sends the raw integer. If this order ever drifts from
      // libVLC's enum the numbers keep arriving and quietly mean something
      // else, which is the worst available failure mode.
      expect(VlcVideoOrientation.values.map((o) => o.index).toList(),
          <int>[0, 1, 2, 3, 4, 5, 6, 7]);
      expect(VlcVideoOrientation.values.length, 8);
    });
  });

  group('VlcPlayerValue.displayVideoSize', () {
    test('turns a phone-shot portrait clip upright', () {
      // The case the whole feature exists for: stored 1920x1080 landscape
      // frames plus a quarter turn. Read the size alone and this is a
      // landscape film.
      const value = VlcPlayerValue(
        videoSize: Size(1920, 1080),
        videoOrientation: VlcVideoOrientation.leftBottom,
      );

      expect(value.videoSize, const Size(1920, 1080));
      expect(value.displayVideoSize, const Size(1080, 1920));
    });

    test('leaves an unrotated landscape film alone', () {
      const value = VlcPlayerValue(
        videoSize: Size(1920, 1080),
        videoOrientation: VlcVideoOrientation.topLeft,
      );

      expect(value.displayVideoSize, const Size(1920, 1080));
    });

    test('prefers the reported rotation over the coded buffer', () {
      // A backend that sends both is telling us the same thing twice, but the
      // rotation is the authoritative half: it comes off the same track read
      // as the size, while a coded buffer is padded and can be stale.
      const value = VlcPlayerValue(
        videoSize: Size(1920, 1080),
        videoOrientation: VlcVideoOrientation.rightTop,
        codedVideoSize: Size(1920, 1088),
      );

      expect(value.displayVideoSize, const Size(1080, 1920));
    });

    test('falls back to the coded buffer when no rotation is reported', () {
      // The Darwin texture route. vmem applies the rotation before it
      // negotiates the buffer, so the buffer's shape is the picture's shape.
      const value = VlcPlayerValue(
        videoSize: Size(1920, 1080),
        codedVideoSize: Size(1080, 1920),
      );

      expect(value.displayVideoSize, const Size(1080, 1920));
    });

    test('says unknown rather than guessing from the stored size alone', () {
      // The conservative half of the contract, and the one worth protecting:
      // a backend that reports neither a rotation nor a coded buffer has not
      // said which way up the picture is. 1920x1080 is both a landscape film
      // and a portrait clip, so offering it here would put a coin flip behind
      // a device rotation.
      const value = VlcPlayerValue(videoSize: Size(1920, 1080));

      expect(value.displayVideoSize, isNull);
    });

    test('is null before any size arrives', () {
      const value = VlcPlayerValue();

      expect(value.displayVideoSize, isNull);
    });
  });

  group('orientation off the wire', () {
    // Every event carries a playing state on purpose: idle, opening and error
    // all clear the size by design, so a stateless fixture would test the
    // clearing path and nothing else.
    VlcPlayerValue parse(Map<String, Object?> event) => VlcPlayerValue.fromEvent(
      <String, Object?>{'state': 'playing', ...event},
      const VlcPlayerValue(),
    );

    test('an integer becomes the matching orientation', () {
      final value = parse(<String, Object?>{
        'videoSize': <String, Object?>{'width': 1920, 'height': 1080},
        'videoOrientation': 5,
      });

      expect(value.videoOrientation, VlcVideoOrientation.leftBottom);
      expect(value.displayVideoSize, const Size(1080, 1920));
    });

    test('an absent key means unknown, not upright', () {
      // Unknown has to stay null so displayVideoSize falls through to the next
      // source. Reading it as topLeft would make every backend that does not
      // report a rotation claim its videos are already upright.
      final value = parse(<String, Object?>{
        'videoSize': <String, Object?>{'width': 1920, 'height': 1080},
      });

      expect(value.videoOrientation, isNull);
    });

    test('a value outside the enum is refused rather than clamped', () {
      for (final bad in <Object?>[-1, 8, 99, 'leftBottom', double.nan, null]) {
        final value = parse(<String, Object?>{
          'videoSize': <String, Object?>{'width': 1920, 'height': 1080},
          'videoOrientation': bad,
        });

        expect(value.videoOrientation, isNull, reason: 'for $bad');
      }
    });

    test('a new media clears the previous clip\'s rotation with its size', () {
      // Carrying a portrait clip's rotation onto the next film's dimensions is
      // how a landscape feature would open sideways.
      final portrait = parse(<String, Object?>{
        'videoSize': <String, Object?>{'width': 1920, 'height': 1080},
        'videoOrientation': 5,
      });
      expect(portrait.videoOrientation, VlcVideoOrientation.leftBottom);

      final cleared = portrait.copyWith(clearVideoSize: true);

      expect(cleared.videoOrientation, isNull);
      expect(cleared.videoSize, isNull);
      expect(cleared.displayVideoSize, isNull);
    });

    test('the rotation takes part in equality', () {
      const a = VlcPlayerValue(
        videoSize: Size(1920, 1080),
        videoOrientation: VlcVideoOrientation.topLeft,
      );
      const b = VlcPlayerValue(
        videoSize: Size(1920, 1080),
        videoOrientation: VlcVideoOrientation.leftBottom,
      );

      expect(a, isNot(b));
      expect(a.hashCode, isNot(b.hashCode));
    });
  });

  group('the Android side of the wire', () {
    // No CI machine runs the Android plugin and its one unit test is a stub,
    // so the contract is asserted against the source text - the same idiom as
    // native_teardown_order_test.dart. What matters is that the two keys are
    // emitted together off a single track read.
    late String source;

    setUpAll(() {
      source = File(
        'android/src/main/kotlin/com/lingjhf/vlc_player/VlcPlayerPlatformView.kt',
      ).readAsStringSync();
    });

    test('emits the orientation beside the size', () {
      expect(source, contains('event["videoOrientation"] = track.orientation'));
      expect(source, contains('event["videoSize"] = mapOf('));
    });

    test('reads the track once, not once per field', () {
      // currentVideoTrack walks the media's track array on every access and
      // this runs on every snapshot, so a second read is a real cost.
      final shape = RegExp(
        r'private fun putVideoShape\(.*?\n    \}',
        dotAll: true,
      ).firstMatch(source);
      expect(shape, isNotNull, reason: 'putVideoShape not found');
      expect(
        'currentVideoTrack'.allMatches(shape!.group(0)!).length,
        1,
        reason: 'One read feeds both keys.',
      );
    });

    test('sends nothing at all until a video track exists', () {
      // A shape guessed while the player is still opening is a rotation the
      // device would act on and then have to undo.
      expect(
        source,
        contains('val track = mediaPlayer.currentVideoTrack ?: return'),
      );
    });

    test('does not do the swap on the Kotlin side', () {
      // The predicate lives in Dart because that is the only side of this
      // channel CI runs tests on. If a swap appears here, the two sides can
      // disagree and nothing would catch it.
      expect(source, isNot(contains('orientation and 4')));
      expect(source, isNot(contains('orientation == 5')));
    });
  });
}
