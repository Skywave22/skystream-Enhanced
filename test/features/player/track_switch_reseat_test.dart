import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_tracks_tab.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart';

import 'fake_vlc_engine.dart';

/// Switching a track lands now, not one caching interval from now.
///
/// A stream selected mid-playback begins at the demuxer's read point, which
/// sits a whole caching interval ahead of the picture, so the newly chosen
/// audio stays silent while the clock catches up. Re-issuing the current
/// position flushes every stream and refills them together, which is the same
/// thing a viewer discovers by scrubbing a little after switching - and it is
/// what mpv did for free.
void main() {
  Future<VlcPlayerController> attach(FakeVlcEngine engine) async {
    engine.install();
    addTearDown(engine.dispose);
    return engine.attach();
  }

  Future<void> pumpTracksTab(
    WidgetTester tester, {
    required VlcPlayerController controller,
    required PlayerTrackKind kind,
    required List<VlcTrackDescription> tracks,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PlayerTracksTab(
            controller: controller,
            kind: kind,
            tracks: tracks,
            trackInfo: const <VlcMediaTrackInfo>[],
            onTracksChanged: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// A player a minute into a seekable film.
  FakeVlcEngine playingEngine() => FakeVlcEngine()
    ..audio = <Map<String, Object?>>[
      <String, Object?>{'id': 1, 'name': 'English', 'language': 'eng'},
      <String, Object?>{'id': 3, 'name': 'French', 'language': 'fra'},
    ]
    ..activeAudioId = 1;

  const tracks = <VlcTrackDescription>[
    VlcTrackDescription(id: 1, name: 'English', language: 'eng'),
    VlcTrackDescription(id: 3, name: 'French', language: 'fra'),
  ];

  testWidgets('choosing an audio track re-seats playback where it is', (
    tester,
  ) async {
    final engine = playingEngine();
    final controller = await attach(engine);
    await engine.emit(<String, Object?>{
      'position': 60000,
      'duration': 600000,
    });
    await tester.pump(const Duration(milliseconds: 400));

    await pumpTracksTab(
      tester,
      controller: controller,
      kind: PlayerTrackKind.audio,
      tracks: tracks,
    );

    await tester.tap(find.text('French'));
    await tester.pumpAndSettle();

    expect(engine.methods, contains('setAudioTrack'));
    expect(
      engine.methods.indexOf('seekTo'),
      greaterThan(engine.methods.indexOf('setAudioTrack')),
      reason: 'the flush has to come after the switch, or it flushes the old '
          'selection and changes nothing',
    );
    expect(
      (engine.callsTo('seekTo').last.arguments
          as Map<Object?, Object?>)['position'],
      60000,
      reason: 're-issued where the viewer already is, not somewhere else',
    );

    controller.dispose();
  });

  testWidgets('turning subtitles off does not pay for a rebuffer', (
    tester,
  ) async {
    // Nothing has to be fetched to show nothing, so the flush would be a
    // spinner in exchange for no benefit at all.
    final engine = playingEngine()
      ..subtitle = <Map<String, Object?>>[
        <String, Object?>{'id': 5, 'name': 'English', 'language': 'eng'},
      ]
      ..activeSubtitleId = 5;
    final controller = await attach(engine);
    await engine.emit(<String, Object?>{
      'position': 60000,
      'duration': 600000,
    });
    await tester.pump(const Duration(milliseconds: 400));

    await pumpTracksTab(
      tester,
      controller: controller,
      kind: PlayerTrackKind.subtitle,
      tracks: const <VlcTrackDescription>[
        VlcTrackDescription(id: 5, name: 'English', language: 'eng'),
      ],
    );

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.tap(find.text(l10n.off));
    await tester.pumpAndSettle();

    expect(engine.methods, contains('disableSubtitle'));
    expect(engine.methods, isNot(contains('seekTo')));

    controller.dispose();
  });

  testWidgets('a live feed is never re-seated', (tester) async {
    // There is nowhere to seek to, and asking would fail the call.
    final engine = playingEngine();
    final controller = await attach(engine);
    await engine.emit(<String, Object?>{
      'position': 60000,
      'duration': 0,
      'isLive': true,
      'isSeekable': false,
    });
    await tester.pump(const Duration(milliseconds: 400));

    await pumpTracksTab(
      tester,
      controller: controller,
      kind: PlayerTrackKind.audio,
      tracks: tracks,
    );

    await tester.tap(find.text('French'));
    await tester.pumpAndSettle();

    expect(engine.methods, contains('setAudioTrack'));
    expect(engine.methods, isNot(contains('seekTo')));

    controller.dispose();
  });
}
