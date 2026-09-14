import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/playback_recovery.dart';

import 'fake_vlc_engine.dart';
import 'vlc_screen_harness.dart';

/// The viewer's audio and subtitle choice survives a reopen.
///
/// A failover, a same-source recovery and a rendition step-down all hand
/// libVLC new media with nobody having asked for it. The reopen restores the
/// position and, until this existed, nothing else - so a viewer watching a
/// dubbed film or reading subtitles was put back on the engine's own default
/// partway through, with no event they could connect it to.
void main() {
  late FakeVlcEngine engine;

  setUp(() {
    engine = FakeVlcEngine();
    installEngineMocks(engine: engine);
  });
  tearDown(removeEngineMocks);

  /// Freezes the position until the watchdog gives up and reopens the media.
  ///
  /// The reported path: nothing the viewer did, the source simply stopped
  /// answering, and the recovery took their audio with it.
  Future<void> stallUntilReopen(WidgetTester tester) async {
    final beyond = kStallRecoverAfter + const Duration(seconds: 5);
    for (var i = 0; i < beyond.inSeconds; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await settle(tester);
  }

  testWidgets('a recovery puts the viewer back on the track they chose', variant: texturePlatform, (
    tester,
  ) async {
    engine.audio = const <Map<String, Object?>>[
      <String, Object?>{'id': 1, 'name': 'English', 'language': 'eng'},
      <String, Object?>{'id': 3, 'name': 'French', 'language': 'fra'},
    ];
    engine.activeAudioId = 3;

    await pumpPlayer(tester);
    await sendEvent(tester, engine.event());
    await settle(tester);

    // What a reopen does: the engine comes back on its own default.
    engine.activeAudioId = 1;
    final before = engine.callsTo('setAudioTrack').length;

    await stallUntilReopen(tester);
    await sendEvent(tester, engine.event());
    await settle(tester);

    final asked = engine
        .callsTo('setAudioTrack')
        .skip(before)
        .map((c) => (c.arguments as Map<Object?, Object?>)['id'])
        .toList();

    expect(
      asked,
      contains(3),
      reason: 'the viewer chose French; a recovery is not a change of mind',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a reopen follows the language, not the number', variant: texturePlatform, (
    tester,
  ) async {
    engine.audio = const <Map<String, Object?>>[
      <String, Object?>{'id': 1, 'name': 'English', 'language': 'eng'},
      <String, Object?>{'id': 3, 'name': 'French', 'language': 'fra'},
    ];
    engine.activeAudioId = 3;

    await pumpPlayer(tester);
    await sendEvent(tester, engine.event());
    await settle(tester);

    // The source that comes back numbers its tracks differently, which is what
    // a failover to another provider's copy looks like.
    engine.audio = const <Map<String, Object?>>[
      <String, Object?>{'id': 5, 'name': 'English', 'language': 'eng'},
      <String, Object?>{'id': 7, 'name': 'French', 'language': 'fra'},
    ];
    engine.activeAudioId = 5;
    final before = engine.callsTo('setAudioTrack').length;

    await stallUntilReopen(tester);
    await sendEvent(tester, engine.event());
    await settle(tester);

    final asked = engine
        .callsTo('setAudioTrack')
        .skip(before)
        .map((c) => (c.arguments as Map<Object?, Object?>)['id'])
        .toList();

    expect(asked, contains(7), reason: 'French is id 7 on this one');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a reopen leaves the default alone when the language is gone', variant: texturePlatform, (
    tester,
  ) async {
    // The dangerous case: id 3 still exists and is now German.
    engine.audio = const <Map<String, Object?>>[
      <String, Object?>{'id': 1, 'name': 'English', 'language': 'eng'},
      <String, Object?>{'id': 3, 'name': 'French', 'language': 'fra'},
    ];
    engine.activeAudioId = 3;

    await pumpPlayer(tester);
    await sendEvent(tester, engine.event());
    await settle(tester);

    engine.audio = const <Map<String, Object?>>[
      <String, Object?>{'id': 1, 'name': 'English', 'language': 'eng'},
      <String, Object?>{'id': 3, 'name': 'German', 'language': 'deu'},
    ];
    engine.activeAudioId = 1;
    final before = engine.callsTo('setAudioTrack').length;

    await stallUntilReopen(tester);
    await sendEvent(tester, engine.event());
    await settle(tester);

    final asked = engine
        .callsTo('setAudioTrack')
        .skip(before)
        .map((c) => (c.arguments as Map<Object?, Object?>)['id'])
        .toList();

    expect(
      asked,
      isNot(contains(3)),
      reason: 'German is not French; the engine default beats a wrong guess',
    );

    await tester.pumpWidget(const SizedBox());
  });
}
