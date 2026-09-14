/// Skip Outro, from the screen down: what the press does to the session, and
/// which prompt owns the bottom-right corner while it happens.
///
/// The press means the viewer is done with the episode, so it raises the
/// up-next card at once rather than seeking to the end of the credits band,
/// which on an encode whose credits end before the file does leaves a
/// next-episode preview or a logo tail playing.
///
/// The seek still happens, before anything advances, and it lands past the
/// completion line rather than on the band's end: `PlaybackTracker.finish()`
/// judges the session from the last sample taken while playing and
/// `_markedWatched` needs `sample.isComplete`, so an advance issued from
/// inside an outro that started at 83 % reports a `scrobbleStop` to Trakt and
/// Simkl where the viewer earned a play.
///
/// Only one prompt owns the corner. The chip and the up-next card are both
/// bottom-right and the card is a later child of the screen's Stack, so a
/// surviving chip is a tap that lands on the card on touch and an invisible
/// D-pad stop inside the card's rectangle on a remote.
library;

import 'package:dio/dio.dart' show Dio;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/services/download_service.dart';
import 'package:skystream/core/storage/settings_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/features/player/presentation/vlc/ended_card.dart';
import 'package:skystream/features/player/presentation/vlc/next_episode_countdown.dart';
import 'package:skystream/features/player/presentation/widgets/player_control_components.dart'
    show PlayerActionButton;
import 'package:skystream/features/skip/data/intro_db_service.dart';
import 'package:skystream/features/skip/data/skip_service.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import 'fake_vlc_engine.dart';
import 'vlc_screen_harness.dart';

/// Both segment sources are opt-in and off by default in the harness, so a
/// test that wants a chip at all has to turn one on.
class _SkipOn extends SettingsRepository {
  _SkipOn() : super(StorageService());

  @override
  bool isIntroDbIntegrationEnabled() => true;

  @override
  bool isAnimeSkipIntegrationEnabled() => false;
}

/// IntroDB, answering from the test rather than from the network. Subclassed
/// rather than faked to an interface because the provider is typed on the
/// concrete service.
class _FixedSegments extends IntroDbService {
  _FixedSegments(this.segments) : super(Dio());

  final List<SkipSegment> segments;

  @override
  Future<List<SkipSegment>> getSkipSegments({
    int? tmdbId,
    String? imdbId,
    int? anilistId,
    required int season,
    required int episode,
    int? duration,
  }) async => segments;
}

/// Twenty minutes, so a percentage of it is a round number of milliseconds.
const int _durationMs = 1200000;

/// The anime shape the advance exists for: credits from 16:40 to 17:40 of a
/// 20:00 file, with a next-episode preview after them. The band ends at
/// 88.3 %, short of the 90 % completion line.
List<SkipSegment> _outroWithTail() => <SkipSegment>[
  SkipSegment(startTime: 1000, endTime: 1060, type: SkipType.outro),
];

/// Credits that run into the last fifteen seconds, so the chip and the
/// automatic card are up at the same moment.
List<SkipSegment> _outroToTheEnd() => <SkipSegment>[
  SkipSegment(startTime: 1100, endTime: 1195, type: SkipType.outro),
];

void main() {
  late FakeVlcEngine engine;

  setUp(() {
    engine = FakeVlcEngine();
    installEngineMocks(engine: engine);
  });
  tearDown(removeEngineMocks);

  Future<AppLocalizations> english() =>
      AppLocalizations.delegate.load(const Locale('en'));

  final firstEpisode = Episode(
    name: 'Ep 01',
    url: 'https://example.com/e1.mp4',
    season: 1,
    episode: 1,
  );
  final lastEpisode = Episode(
    name: 'Ep 02',
    url: 'https://example.com/e2.mp4',
    season: 1,
    episode: 2,
  );
  final show = MultimediaItem(
    title: 'Show',
    url: 'https://example.com/show',
    posterUrl: '',
    contentType: MultimediaContentType.series,
    episodes: [firstEpisode, lastEpisode],
    provider: 'Remote',
  );

  /// Every seekTo the engine received, in milliseconds.
  List<int> seeks() => engine
      .callsTo('seekTo')
      .map((call) => (call.arguments as Map)['position'] as int)
      .toList(growable: false);

  /// Every media the engine was handed. One per episode opened.
  int opens() => engine.callsTo('setSource').length;

  /// The show playing [episode] with real skip bands, and with the disk lookup
  /// that opens every advance held shut so a test can see whether one even
  /// started.
  ///
  /// Hands back a getter: the download service is built the first time an
  /// advance reads it, so null means no advance ever ran.
  Future<GatedDownloads? Function()> pumpShow(
    WidgetTester tester, {
    required Episode episode,
    required List<SkipSegment> segments,
    bool isTv = true,
  }) async {
    GatedDownloads? downloads;
    await pumpPlayer(
      tester,
      item: show,
      episode: episode,
      videoUrl: episode.url,
      isTv: isTv,
      overrides: [
        downloadServiceProvider.overrideWith(
          (ref) => downloads = GatedDownloads(ref),
        ),
        settingsRepositoryProvider.overrideWithValue(_SkipOn()),
        introDbServiceProvider.overrideWithValue(_FixedSegments(segments)),
      ],
    );
    await sendFirstFrame(tester);
    return () => downloads;
  }

  /// Playback reaching [ms], with the duration settled - the tracker only
  /// trusts a length it has been told twice.
  Future<void> playTo(WidgetTester tester, int ms) async {
    await sendEvent(
      tester,
      snapshot(position: ms - 1000, duration: _durationMs),
    );
    await sendEvent(tester, snapshot(position: ms, duration: _durationMs));
  }

  Finder chip() => find.byType(PlayerActionButton);
  Finder card() => find.byType(NextEpisodeCountdown);

  group('the press means the episode, not the credits', () {
    testWidgets(
      'Skip Outro raises the up-next card at once',
      variant: texturePlatform,
      (tester) async {
        final downloads = await pumpShow(
          tester,
          episode: firstEpisode,
          segments: _outroWithTail(),
        );
        final l10n = await english();

        await playTo(tester, 1010000);
        expect(chip(), findsOneWidget, reason: 'inside the credits');
        expect(
          tester.widget<PlayerActionButton>(chip()).label,
          l10n.next,
          reason: 'with an episode behind it the chip says what it does',
        );
        expect(card(), findsNothing, reason: 'still three minutes out');

        await tester.tap(chip());
        await settle(tester);

        expect(card(), findsOneWidget);
        expect(
          find.text(lastEpisode.name),
          findsOneWidget,
          reason: 'the card names the episode that follows',
        );
        expect(
          downloads(),
          isNull,
          reason:
              'the card is an offer, not an advance: nothing is resolved until '
              'Play now or the countdown says so',
        );

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'and seeks past the completion line first, so the play is not '
      'under-reported',
      variant: texturePlatform,
      (tester) async {
        await pumpShow(
          tester,
          episode: firstEpisode,
          segments: _outroWithTail(),
        );

        await playTo(tester, 1010000);
        expect(seeks(), isEmpty);

        await tester.tap(chip());
        await settle(tester);

        expect(
          seeks(),
          <int>[1140000],
          reason:
              '95 % of the file, not the band end at 1060 s (88.3 %). '
              'PlaybackTracker.finish() reads the last sample taken while '
              'playing, and below 90 % that is a scrobbleStop rather than a '
              'play',
        );

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'on the last episode it is an ordinary skip and no card',
      variant: texturePlatform,
      (tester) async {
        final downloads = await pumpShow(
          tester,
          episode: lastEpisode,
          segments: _outroWithTail(),
        );
        final l10n = await english();

        await playTo(tester, 1010000);
        expect(
          tester.widget<PlayerActionButton>(chip()).label,
          l10n.skipOutro,
          reason: 'there is nothing to advance to, so it is still a skip',
        );

        await tester.tap(chip());
        await settle(tester);

        expect(seeks(), <int>[
          1060000,
        ], reason: 'the end of the band, as before');
        expect(card(), findsNothing);
        expect(downloads(), isNull);

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('one advance, however the card is summoned', () {
    // The card's `_settled` latch has a second entry point. Left open, a
    // countdown finishing behind an advance that end-of-media already started
    // opens two media and skips an episode nobody asked to skip.
    testWidgets(
      'the summoned countdown running out opens exactly one media',
      variant: texturePlatform,
      (tester) async {
        final downloads = await pumpShow(
          tester,
          episode: firstEpisode,
          segments: _outroWithTail(),
        );
        final openedFirstEpisode = opens();

        await playTo(tester, 1010000);
        await tester.tap(chip());
        await settle(tester);
        expect(card(), findsOneWidget);

        // The countdown runs out on its own, which is the card's other way of
        // saying Play now.
        await tester.pump(const Duration(seconds: 15));
        await settle(tester);
        expect(downloads(), isNotNull, reason: 'the advance started');

        // The outgoing engine delivers its end of media late, into the
        // transition - the race `_advance` reports `playing` for.
        await sendEvent(tester, snapshot(state: 'ended'));
        await settle(tester);

        downloads()!.gate.complete();
        await settle(tester);

        expect(
          opens() - openedFirstEpisode,
          1,
          reason: 'one press, one episode',
        );

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'cancelling a summoned card does not bring it back',
      variant: texturePlatform,
      (tester) async {
        final downloads = await pumpShow(
          tester,
          episode: firstEpisode,
          segments: _outroWithTail(),
        );
        final l10n = await english();

        await playTo(tester, 1010000);
        await tester.tap(chip());
        await settle(tester);
        expect(card(), findsOneWidget);

        await tester.tap(find.text(l10n.cancel));
        await settle(tester);
        expect(card(), findsNothing);

        // The credits play out, and then the file does.
        await playTo(tester, 1180000);
        await settle(tester);
        expect(card(), findsNothing, reason: 'one refusal per episode');

        await sendEvent(tester, snapshot(state: 'ended'));
        await settle(tester);

        expect(
          downloads(),
          isNull,
          reason:
              'owner decision 2: the refusal is honoured at end of media too, '
              'which is the one outcome Cancel exists to produce',
        );

        await tester.pumpWidget(const SizedBox());
      },
    );

    // `_maybeOfferNextEpisode` early-returns on a refusal; a deliberate press
    // clears it instead. Left standing, the refusal would both keep the card
    // down and hold the advance back at end of media, so the press has to
    // raise the card AND the episode has to actually follow.
    testWidgets(
      'a refusal in the automatic window does not veto a deliberate press',
      variant: texturePlatform,
      (tester) async {
        final downloads = await pumpShow(
          tester,
          episode: firstEpisode,
          segments: _outroToTheEnd(),
        );
        final l10n = await english();

        // Inside the last fifteen seconds, so the card comes up by itself.
        await playTo(tester, 1190000);
        await settle(tester);
        expect(card(), findsOneWidget, reason: 'the automatic offer');
        expect(chip(), findsNothing, reason: 'and the chip stood down for it');

        await tester.tap(find.text(l10n.cancel));
        await settle(tester);
        expect(card(), findsNothing);
        expect(
          chip(),
          findsOneWidget,
          reason: 'the corner is the chip\'s again',
        );

        await tester.tap(chip());
        await settle(tester);

        expect(
          card(),
          findsOneWidget,
          reason: 'a press is not the automatic offer, and is not refused',
        );

        // And the credits run out under the card the press raised.
        await sendEvent(
          tester,
          snapshot(position: 1199000, duration: _durationMs),
        );
        await sendEvent(tester, snapshot(state: 'ended'));
        await settle(tester);

        expect(
          downloads(),
          isNotNull,
          reason:
              'the refusal was spent on the automatic offer. Left standing it '
              'would reach owner decision 2 and hold the advance back at end '
              'of media as well',
        );
        expect(
          find.byKey(endedCardKey),
          findsNothing,
          reason: 'this episode was not declined; it was chosen',
        );

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('one prompt owns the corner', () {
    testWidgets(
      'the skip chip and the up-next card are never both mounted',
      variant: texturePlatform,
      (tester) async {
        await pumpShow(
          tester,
          episode: firstEpisode,
          segments: _outroToTheEnd(),
        );

        // Inside the band and clear of the automatic window: the chip alone.
        await playTo(tester, 1120000);
        expect(chip(), findsOneWidget);
        expect(card(), findsNothing);

        // The last fifteen seconds, still inside the band: the card alone.
        await playTo(tester, 1190000);
        await settle(tester);
        expect(
          card(),
          findsOneWidget,
          reason: 'the automatic offer, over a still-live outro band',
        );
        expect(
          chip(),
          findsNothing,
          reason:
              'the chip is outside the chrome, so nothing else would have '
              'taken it down; underneath the card it is a tap that misses and '
              'a focus stop nobody can see',
        );

        await tester.pumpWidget(const SizedBox());
      },
    );

    // The press that raises the card is the press aimed at the chip, so the
    // remote is on the chip at the instant it goes. The card owns a
    // FocusScopeNode and autofocuses Play now; the chip must not leave the
    // remote on the route scope or the key sink, where `bare && _isTv &&
    // _isDirectional` answers every arrow with `handled`.
    testWidgets(
      'the remote follows the card off the chip it was sitting on',
      variant: texturePlatform,
      (tester) async {
        await pumpShow(
          tester,
          episode: firstEpisode,
          segments: _outroWithTail(),
        );

        await playTo(tester, 1010000);
        final skipNode = FocusManager.instance.rootScope.descendants.firstWhere(
          (node) => node.debugLabel == 'player-skip-chip',
        );
        skipNode.requestFocus();
        await tester.pump();
        expect(FocusManager.instance.primaryFocus, skipNode);

        await tester.tap(chip());
        await settle(tester);

        final primary = FocusManager.instance.primaryFocus!;
        expect(primary, isNot(isA<FocusScopeNode>()));
        expect(
          primary.debugLabel,
          kPlayNextFocusLabel,
          reason: 'the card took the remote the chip was holding',
        );

        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}
