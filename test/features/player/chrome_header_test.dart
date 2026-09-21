import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/player/presentation/widgets/player_control_components.dart'
    show PlayerTopBar;

import 'vlc_screen_harness.dart';

/// What the top bar says it is playing.
///
/// Two facts, and which line each belongs on. The title is the whole of what
/// was chosen - the film, or the series *and* the episode inside it - because
/// a viewer scanning the bar is checking they are in the right place, and a
/// series title alone does not answer that on episode nine. The subtitle is
/// the source the picture is coming from, which is otherwise visible only by
/// opening the panel and is the first thing anyone asks when a stream is
/// misbehaving.
///
/// The bar gives the title one line and ellipsises it, so the order inside it
/// is load-bearing: series, then numbering, then the episode's own name. A
/// phone loses the end of that, which is the part it can afford to lose.
void main() {
  setUp(installEngineMocks);
  tearDown(removeEngineMocks);

  MultimediaItem series(List<Episode> episodes) => MultimediaItem(
    title: 'Legend of Exorcism',
    url: 'https://example.com/show',
    posterUrl: '',
    contentType: MultimediaContentType.series,
    episodes: episodes,
    provider: 'Remote',
  );

  Episode ep(int season, int number, {String name = ''}) => Episode(
    name: name,
    url: 'https://example.com/s${season}e$number.mp4',
    season: season,
    episode: number,
  );

  PlayerTopBar bar(WidgetTester tester) =>
      tester.widget<PlayerTopBar>(find.byType(PlayerTopBar));

  testWidgets('a film is its own title, and nothing is invented under it', (
    tester,
  ) async {
    await pumpPlayer(tester);
    await sendFirstFrame(tester);

    expect(bar(tester).title, 'Channel One');
    // Nothing is playing from a named provider here, so there is no second
    // line rather than an empty one.
    expect(bar(tester).subtitle, anyOf(isNull, isNot('')));

    await sendEvent(tester, snapshot(state: 'paused'));
  }, variant: texturePlatform);

  testWidgets('a series carries its episode in the title', (tester) async {
    final episodes = <Episode>[
      ep(1, 1, name: 'A Fated Meeting'),
      ep(1, 2, name: "Hongjun Encounters Jinglong in Chang'an"),
    ];
    await pumpPlayer(
      tester,
      item: series(episodes),
      episode: episodes[1],
      videoUrl: episodes[1].url,
    );
    await sendFirstFrame(tester);

    expect(
      bar(tester).title,
      "Legend of Exorcism · S1 E2 · Hongjun Encounters Jinglong in Chang'an",
      reason: 'series, then numbering, then the episode name, in that order',
    );

    await sendEvent(tester, snapshot(state: 'paused'));
  }, variant: texturePlatform);

  testWidgets('numbering a plugin never filled in is left out', (tester) async {
    // A great many plugins hand back zeroes, and `S0 E0` is worse than saying
    // nothing at all.
    final episodes = <Episode>[ep(0, 0, name: 'Pilot')];
    await pumpPlayer(
      tester,
      item: series(episodes),
      episode: episodes.first,
      videoUrl: episodes.first.url,
    );
    await sendFirstFrame(tester);

    expect(bar(tester).title, 'Legend of Exorcism · Pilot');

    await sendEvent(tester, snapshot(state: 'paused'));
  }, variant: texturePlatform);

  testWidgets('an episode with no name of its own is just the numbering', (
    tester,
  ) async {
    final episodes = <Episode>[ep(2, 7)];
    await pumpPlayer(
      tester,
      item: series(episodes),
      episode: episodes.first,
      videoUrl: episodes.first.url,
    );
    await sendFirstFrame(tester);

    expect(bar(tester).title, 'Legend of Exorcism · S2 E7');

    await sendEvent(tester, snapshot(state: 'paused'));
  }, variant: texturePlatform);

  testWidgets('the subtitle names the source that is playing', (tester) async {
    await pumpPlayer(
      tester,
      preloadedStreams: const <StreamResult>[
        StreamResult(
          url: 'https://a.test/one',
          source: 'HubCloud [1080p]',
          providerName: 'Torrentio',
        ),
      ],
      videoUrl: 'https://a.test/one',
    );
    await sendFirstFrame(tester);

    expect(
      bar(tester).subtitle,
      'Torrentio',
      reason: 'the provider, which is what the panel calls it too',
    );

    await sendEvent(tester, snapshot(state: 'paused'));
  }, variant: texturePlatform);

  testWidgets('a source naming no provider falls back to its own label', (
    tester,
  ) async {
    // `Unknown` is StreamResult's placeholder, not a provider: shown, it would
    // put the word Unknown under every title on every JS plugin's stream.
    await pumpPlayer(
      tester,
      preloadedStreams: const <StreamResult>[
        StreamResult(
          url: 'https://a.test/one',
          source: 'HubCloud [1080p] 2.1 GB',
          providerName: 'Unknown',
        ),
      ],
      videoUrl: 'https://a.test/one',
    );
    await sendFirstFrame(tester);

    expect(bar(tester).subtitle, isNot(contains('Unknown')));
    expect(bar(tester).subtitle, contains('HubCloud'));

    await sendEvent(tester, snapshot(state: 'paused'));
  }, variant: texturePlatform);
}
