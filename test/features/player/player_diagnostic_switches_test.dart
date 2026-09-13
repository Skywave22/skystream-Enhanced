/// The two run-time diagnostic switches, wired through the real screen.
///
/// They exist for one job: a crash on Linux that nobody here can reproduce,
/// where the only instrument is a person running one binary twice. That makes
/// the wiring the part worth testing rather than the flags - a switch that
/// parses correctly and reaches nothing is worse than no switch, because the
/// answer it produces is a confident wrong one.
///
/// Both are asserted in both positions. The off case is the one that protects
/// every user who never sets them.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/player_debug_flags.dart';
import 'package:vlc_player/vlc_player.dart';

import 'fake_vlc_engine.dart';
import 'vlc_screen_harness.dart';

void main() {
  late FakeVlcEngine engine;

  setUp(() {
    engine = FakeVlcEngine();
    installEngineMocks(engine: engine);
    PlayerDiagnostics.environment = const <String, String>{};
    addTearDown(() => PlayerDiagnostics.environment = const <String, String>{});
  });
  tearDown(removeEngineMocks);

  /// The instance options the engine was actually created with - what libVLC
  /// is handed, rather than what the config object holds.
  List<String> createdOptions() {
    final create = engine.callsTo('create').single;
    final arguments = create.arguments as Map<Object?, Object?>;
    return (arguments['options'] as List<Object?>).cast<String>();
  }

  /// The video surface as Flutter's own finders see it.
  ///
  /// Two finders rather than a read of the [Offstage] widget, because the two
  /// together say the thing that matters and neither says it alone: the
  /// default finder skips offstage subtrees, so [painted] failing to find the
  /// player is exactly "it is not being composited", while [mounted] finding
  /// it is "the State that attaches the native player is alive". Reading the
  /// flag back off an `Offstage` would only prove the flag was consulted.
  final painted = find.byType(VlcPlayer);
  final mounted = find.byType(VlcPlayer, skipOffstage: false);

  group('SKYSTREAM_VLC_VERBOSE', () {
    // The default, and the one that matters most: a normal build stays quiet.
    testWidgets('a normal launch leaves libVLC quiet', variant: texturePlatform, (
      tester,
    ) async {
      await pumpPlayer(tester);
      await settle(tester);

      expect(createdOptions(), contains('--quiet'));
      expect(createdOptions(), isNot(contains('--verbose=2')));

      await tester.pumpWidget(const SizedBox());
    });

    // The whole point of the switch. Without this reaching the config the
    // friend's terminal stays empty and the round trip produces nothing.
    testWidgets(
      'the switch raises libVLC to verbose=2',
      variant: texturePlatform,
      (tester) async {
        PlayerDiagnostics.environment = const <String, String>{
          'SKYSTREAM_VLC_VERBOSE': '1',
        };

        await pumpPlayer(tester);
        await settle(tester);

        expect(
          createdOptions(),
          contains('--verbose=2'),
          reason:
              'libVLC writes its own log to stderr, so this option is the '
              'only thing standing between a silent crash and a transcript',
        );
        expect(createdOptions(), isNot(contains('--quiet')));

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('SKYSTREAM_NO_VIDEO', () {
    testWidgets(
      'a normal launch paints the video surface',
      variant: texturePlatform,
      (tester) async {
        await pumpPlayer(tester);
        await settle(tester);

        expect(painted, findsOneWidget);

        await tester.pumpWidget(const SizedBox());
      },
    );

    // The bisection. The engine has to be created and the media set exactly as
    // they always were - a run that suppresses playback along with the picture
    // proves nothing about where a crash lives, because there is no playback
    // left to crash.
    testWidgets(
      'the switch drops the picture and keeps the player',
      variant: texturePlatform,
      (tester) async {
        PlayerDiagnostics.environment = const <String, String>{
          'SKYSTREAM_NO_VIDEO': '1',
        };

        await pumpPlayer(tester);
        await settle(tester);

        expect(
          painted,
          findsNothing,
          reason:
              'an offstage subtree is not painted, so the Texture layer is '
              'never composited and the embedder never asks the plugin for a '
              'pixel buffer',
        );
        expect(
          mounted,
          findsOneWidget,
          reason:
              'VlcPlayer.initState is what attaches the native player on the '
              'texture platforms - leaving it out of the tree would be no '
              'player at all rather than a player with no picture',
        );
        expect(
          engine.callsTo('create'),
          hasLength(1),
          reason: 'the engine still has to exist for audio to be evidence',
        );
        expect(
          engine.callsTo('setSource'),
          isNotEmpty,
          reason: 'and it still has to be given the media',
        );

        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}
