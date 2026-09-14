/// [SubtitleDefault], driven through the real screen over the real engine
/// fake, because the setting is not a field - it is a claim about what the
/// engine has selected once media has finished opening.
///
/// Three things select a subtitle without anybody asking, and each has its own
/// test here:
///
///  * a side-car add, which every native backend makes with libVLC's select
///    flag hardcoded true, so the add re-selects and Off can only be applied
///    AFTER the batch - and on a session's first open the adds are replayed on
///    attach, after the open chain has already finished;
///  * libVLC choosing an EMBEDDED track for itself on the input thread, which
///    lands as a snapshot some time after `setMedia` returned;
///  * the same again on the next media, because a failover, a recovery and an
///    episode advance are each a fresh open.
///
/// And one thing must be able to select one: the viewer, from the Subtitles
/// tab, with nothing turning it back off again for that media.
///
/// Every assertion about what is on goes through [FakeVlcEngine.emit] rather
/// than the harness's `snapshot()`, because only the fake's own snapshot
/// carries `subtitleTrack` - which is the single channel all of this travels
/// on, and the harness's does not have it.
///
/// Harness rules apply - `settle`, never `pumpAndSettle`, and every test
/// unmounts in-body so no watchdog timer outlives it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel.dart'
    show PlayerPanel;
import 'package:skystream/features/player/presentation/vlc/panel/player_panel_row.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import 'fake_vlc_engine.dart';
import 'vlc_screen_harness.dart';

void main() {
  late FakeVlcEngine engine;

  setUp(() {
    engine = FakeVlcEngine();
    installEngineMocks(engine: engine);
  });
  tearDown(removeEngineMocks);

  Future<AppLocalizations> english() =>
      AppLocalizations.delegate.load(const Locale('en'));

  const PlayerSettings auto = PlayerSettings();
  const PlayerSettings off = PlayerSettings(
    subtitleDefault: SubtitleDefault.off,
  );

  /// One healthy snapshot from the fake, past the screen's 250 ms throttle.
  ///
  /// This is the only thing in the harness that tells the screen which
  /// subtitle track is on, and the natives send one on every ordinary tick as
  /// well as on ESAdded.
  Future<void> tick(
    WidgetTester tester, [
    Map<String, Object?> partial = const <String, Object?>{},
  ]) async {
    await engine.emit(partial);
    await tester.pump(const Duration(milliseconds: 400));
  }

  SubtitleFile sub(String name, String lang) =>
      SubtitleFile(url: '/subs/$name.srt', label: name, lang: lang);

  /// A source carrying [subtitles], as a plugin would hand one over.
  ///
  /// Bare paths so the resolver's health probe answers without a socket.
  StreamResult source(String url, {List<SubtitleFile>? subtitles}) =>
      StreamResult(
        url: url,
        source: '1080p',
        providerName: url.split('/').last,
        subtitles: subtitles,
      );

  /// The names of the tracks the engine is holding, in its own order.
  List<Object?> trackNames() =>
      engine.subtitle.map((track) => track['name']).toList();

  /// The name of the track the engine says is on, or null for none.
  Object? selectedTrack() {
    for (final track in engine.subtitle) {
      if (track['id'] == engine.activeSubtitleId) return track['name'];
    }
    return null;
  }

  group('Off', () {
    testWidgets('leaves no subtitle on once the side-cars have been added', (
      tester,
    ) async {
      await pumpPlayer(
        tester,
        preloadedStreams: <StreamResult>[
          source(
            '/sources/alpha.mkv',
            subtitles: <SubtitleFile>[
              sub('english', 'en'),
              sub('french', 'fr'),
            ],
          ),
        ],
        settings: off,
      );

      expect(
        trackNames(),
        <String>['english.srt', 'french.srt'],
        reason:
            'Off must not skip the batch: the Subtitles menu can only offer '
            'tracks that exist, and the whole point is that the viewer can '
            'still turn one on',
      );
      expect(
        selectedTrack(),
        'french.srt',
        reason:
            'the state Off has to undo. Each add selects itself, so the last '
            'one is on before anything here has had a say - which is why '
            'disabling ahead of the batch would achieve nothing',
      );

      // The engine says what it is showing, as it does four times a second.
      await tick(tester);

      expect(engine.activeSubtitleId, -1);
      expect(selectedTrack(), isNull);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('turns off an embedded track libVLC selected for itself', (
      tester,
    ) async {
      await pumpPlayer(
        tester,
        preloadedStreams: <StreamResult>[source('/sources/alpha.mkv')],
        settings: off,
      );

      // No side-cars, so nothing was added and nothing was on while the open
      // chain ran. This is the input thread reaching the media's own subtitle
      // ES afterwards, which is the only way an embedded track ever arrives.
      engine.subtitle = const <Map<String, Object?>>[
        <String, Object?>{'id': 3, 'name': 'Track 3'},
      ];
      engine.activeSubtitleId = 3;
      await engine.bumpTracks();
      await tester.pump(const Duration(milliseconds: 400));

      expect(engine.activeSubtitleId, -1);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('sends one disable per media, not one per tick', (
      tester,
    ) async {
      await pumpPlayer(
        tester,
        preloadedStreams: <StreamResult>[source('/sources/alpha.mkv')],
        settings: off,
      );
      final int before = engine.callsTo('disableSubtitle').length;

      // An engine that keeps reporting the same selected track: a backend that
      // ignored the disable, or simply the next four snapshots before it took
      // effect. Restating a fact is not a second fact.
      engine.subtitle = const <Map<String, Object?>>[
        <String, Object?>{'id': 3, 'name': 'Track 3'},
      ];
      for (var i = 0; i < 4; i++) {
        engine.activeSubtitleId = 3;
        await tick(tester);
      }

      expect(
        engine.callsTo('disableSubtitle').length - before,
        1,
        reason:
            'applied once per media. A rule that fired on every tick could '
            'never let the viewer turn subtitles on at all',
      );

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('lets a track the viewer picks stay picked', (tester) async {
      await pumpPlayer(
        tester,
        preloadedStreams: <StreamResult>[
          source(
            '/sources/alpha.mkv',
            subtitles: <SubtitleFile>[
              sub('english', 'en'),
              sub('french', 'fr'),
            ],
          ),
        ],
        settings: off,
      );
      await tick(tester);
      expect(engine.activeSubtitleId, -1, reason: 'started off, as asked');
      final l10n = await english();

      // The viewer's own route to a subtitle, and the only one there is: the
      // Subtitles tab of the panel, opened from the control bar.
      await tester.tap(find.byTooltip(l10n.subtitles));
      await settle(tester);
      expect(find.byType(PlayerPanel), findsOneWidget);
      await tester.tap(find.widgetWithText(PanelRow, 'english.srt'));
      await settle(tester);

      expect(
        selectedTrack(),
        'english.srt',
        reason: 'Off is a default, not a lock: the menu still works',
      );
      final int disables = engine.callsTo('disableSubtitle').length;

      // Time passes with the pick in place. Nothing may take it away.
      for (var i = 0; i < 4; i++) {
        await tick(tester, <String, Object?>{'position': 3000 + i * 500});
      }
      expect(selectedTrack(), 'english.srt');
      expect(
        engine.callsTo('disableSubtitle').length,
        disables,
        reason: 'the rule stood down when the panel opened and never returns',
      );

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('starts the next source off again after a failover', (
      tester,
    ) async {
      await pumpPlayer(
        tester,
        preloadedStreams: <StreamResult>[
          source(
            '/sources/alpha.mkv',
            subtitles: <SubtitleFile>[sub('english', 'en')],
          ),
          source(
            '/sources/beta.mkv',
            subtitles: <SubtitleFile>[sub('spanish', 'es')],
          ),
        ],
        settings: off,
      );

      // Alpha dies before producing a frame, which is what makes this a
      // failover to another source rather than a retry of this one.
      await tick(tester, <String, Object?>{
        'state': 'error',
        'errorDescription': 'the socket closed',
      });
      await settle(tester);

      expect(
        trackNames(),
        contains('spanish.srt'),
        reason: 'the next candidate really did open and add its own side-car',
      );
      expect(
        engine.activeSubtitleId,
        -1,
        reason:
            'a failover nobody asked for must not switch subtitles on behind '
            'a viewer who set the default to Off',
      );

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('does not carry a pick across a recovery of the same source', (
      tester,
    ) async {
      await pumpPlayer(
        tester,
        preloadedStreams: <StreamResult>[
          source(
            '/sources/alpha.mkv',
            subtitles: <SubtitleFile>[sub('english', 'en')],
          ),
        ],
        settings: off,
      );
      await tick(tester);
      final l10n = await english();

      await tester.tap(find.byTooltip(l10n.subtitles));
      await settle(tester);
      await tester.tap(find.widgetWithText(PanelRow, 'english.srt'));
      await settle(tester);
      expect(selectedTrack(), 'english.srt');

      // The source drops after playing. It is reopened - new media to libVLC,
      // whose side-car batch selects all over again. The documented decision:
      // a pick belongs to the media it was made against, so the reopened media
      // starts from the default like any other. Under Auto the same reopen
      // already overwrites the pick with the preferred language, so this is
      // not a freedom Off is taking away.
      await tick(tester, <String, Object?>{
        'state': 'error',
        'errorDescription': 'the socket closed',
      });
      await settle(tester);

      expect(
        engine.subtitle.length,
        2,
        reason: 'the reopen really did add the side-car a second time',
      );
      expect(engine.activeSubtitleId, -1);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);
  });

  group('Auto', () {
    testWidgets('leaves the side-car the select flag chose exactly where it '
        'was', (tester) async {
      await pumpPlayer(
        tester,
        preloadedStreams: <StreamResult>[
          source(
            '/sources/alpha.mkv',
            // French last and English not preferred-first, so
            // preferredSubtitleIndex names the final add and
            // addSideCarSubtitles has nothing to correct - today's behaviour
            // with no round trip in it.
            subtitles: <SubtitleFile>[
              sub('french', 'fr'),
              sub('english', 'en'),
            ],
          ),
        ],
        settings: auto,
      );
      await tick(tester);

      expect(selectedTrack(), 'english.srt');
      expect(
        engine.methods,
        isNot(contains('disableSubtitle')),
        reason: 'Auto must not touch the selection at all',
      );

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('still selects the preferred language over the last add', (
      tester,
    ) async {
      // On the second open, where the engine is attached and
      // addSideCarSubtitles can read the track list back. English is added
      // FIRST and French last, so the select flag leaves French on and only
      // preferredSubtitleIndex can put English back: this is the one
      // assertion that the Off work did not quietly disarm.
      await pumpPlayer(
        tester,
        preloadedStreams: <StreamResult>[
          source('/sources/alpha.mkv'),
          source(
            '/sources/beta.mkv',
            subtitles: <SubtitleFile>[
              sub('english', 'en'),
              sub('french', 'fr'),
            ],
          ),
        ],
        settings: auto,
      );
      await tick(tester, <String, Object?>{
        'state': 'error',
        'errorDescription': 'the socket closed',
      });
      await settle(tester);

      expect(trackNames(), <String>['english.srt', 'french.srt']);
      expect(
        selectedTrack(),
        'english.srt',
        reason:
            'french.srt was added last and the select flag left it on; '
            'preferredSubtitleIndex is what puts English back',
      );
      expect(engine.methods, isNot(contains('disableSubtitle')));

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('keeps an embedded track libVLC selected for itself', (
      tester,
    ) async {
      await pumpPlayer(
        tester,
        preloadedStreams: <StreamResult>[source('/sources/alpha.mkv')],
        settings: auto,
      );

      engine.subtitle = const <Map<String, Object?>>[
        <String, Object?>{'id': 3, 'name': 'Track 3'},
      ];
      engine.activeSubtitleId = 3;
      await engine.bumpTracks();
      await tester.pump(const Duration(milliseconds: 400));

      expect(engine.activeSubtitleId, 3);
      expect(engine.methods, isNot(contains('disableSubtitle')));

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);
  });
}
