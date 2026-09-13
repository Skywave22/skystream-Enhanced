import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/storage/episode_watch_repository.dart';
import 'package:skystream/core/storage/history_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/features/details/presentation/details_controller.dart';
import 'package:skystream/features/details/presentation/download_launcher.dart';
import 'package:skystream/features/details/presentation/downloaded_file_provider.dart';
import 'package:skystream/features/details/presentation/widgets/episode_card.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// Every history getter is Hive-backed; this card only asks "how far in was
/// this episode", so answer "never watched" and skip the boxes entirely.
class _NoHistory extends HistoryRepository {
  _NoHistory() : super(StorageService());

  @override
  List<HistoryItem> getWatchHistory() => const <HistoryItem>[];

  @override
  int getEpisodePosition(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => 0;

  @override
  int getEpisodeDuration(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => 0;
}

/// The real repository reads its overrides through [StorageService].
class _NoEpisodeWatch extends EpisodeWatchRepository {
  _NoEpisodeWatch(HistoryRepository history)
    : super(StorageService(), history, _ignore);

  static void _ignore() {}

  @override
  bool? getExplicitState(String mainUrl, Episode episode) => null;

  @override
  bool isWatched(String mainUrl, Episode episode) => false;
}

/// The real notifier probes the disk through DownloadService on a post-frame
/// callback; keep the map empty so nothing touches path_provider.
class _FakeDownloadedFiles extends DownloadedFiles {
  @override
  Map<String, File?> build() => const <String, File?>{};

  @override
  Future<void> checkFile(MultimediaItem item, {Episode? episode}) async {}
}

/// Records download launches instead of resolving streams.
class _RecordingLauncher extends DownloadLauncher {
  _RecordingLauncher(super.ref);

  final List<String?> launched = <String?>[];

  @override
  Future<void> launch(
    BuildContext context,
    MultimediaItem item, {
    String? episodeUrl,
  }) async {
    launched.add(episodeUrl);
  }
}

/// Records play presses instead of opening the player.
class _FakeDetailsController extends DetailsController {
  _FakeDetailsController(this._state);

  final DetailsState _state;
  static final List<String?> played = <String?>[];

  @override
  DetailsState build(String itemUrl) => _state;

  @override
  Future<void> handlePlayPress(
    BuildContext context,
    MultimediaItem details, {
    Episode? specificEpisode,
    String? overrideUrl,
  }) async {
    played.add(specificEpisode?.url ?? overrideUrl);
  }
}

const String _kUrl = 'https://fake.test/series/1';

MultimediaItem _parent(List<Episode> episodes) => MultimediaItem(
  title: 'A Series',
  url: _kUrl,
  posterUrl: '',
  contentType: MultimediaContentType.series,
  episodes: episodes,
);

Episode _episode(int number) => Episode(
  name: 'Episode $number',
  url: 'https://fake.test/series/1/e$number',
  season: 1,
  episode: number,
);

/// The download icon of the [index]th card, as its own focus node sees it.
///
/// Resolved through [Focus.of] rather than through a node this test holds, so
/// it answers honestly for any shape of the widget - including one where the
/// icon is wrapped in [ExcludeFocus] and can never be focused at all.
bool _downloadFocused(WidgetTester tester, int index) {
  final icon = find.byIcon(Icons.file_download_outlined).at(index);
  return Focus.of(tester.element(icon), scopeOk: false).hasFocus;
}

FocusNode _bodyNode(WidgetTester tester, int index) => tester
    .widgetList<Focus>(
      find.byWidgetPredicate(
        (w) => w is Focus && w.focusNode?.debugLabel == 'ep_body',
      ),
    )
    .elementAt(index)
    .focusNode!;

class _Harness {
  _Harness(this.launcher, this.container);
  final _RecordingLauncher launcher;
  final ProviderContainer container;
}

/// Pumps [count] episode cards in the layout the details screen builds:
/// [crossAxisCount] cards per row, rows stacked in a column.
Future<_Harness> _pumpCards(
  WidgetTester tester, {
  int count = 2,
  int crossAxisCount = 1,
  Size logicalSize = const Size(960, 540),
  NavigationMode navigationMode = NavigationMode.directional,
  TextDirection textDirection = TextDirection.ltr,
}) async {
  _FakeDetailsController.played.clear();

  tester.view.devicePixelRatio = 2.0;
  tester.view.physicalSize = logicalSize * 2.0;
  addTearDown(tester.view.reset);

  final episodes = List<Episode>.generate(count, (i) => _episode(i + 1));
  final item = _parent(episodes);
  final history = _NoHistory();

  final container = ProviderContainer(
    overrides: [
      historyRepositoryProvider.overrideWithValue(history),
      episodeWatchRepositoryProvider.overrideWithValue(
        _NoEpisodeWatch(history),
      ),
      downloadedFilesProvider.overrideWith(_FakeDownloadedFiles.new),
      downloadLauncherProvider.overrideWith(_RecordingLauncher.new),
      detailsControllerProvider.overrideWith(
        () => _FakeDetailsController(
          DetailsState(details: AsyncValue.data(item), item: item),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  final launcher =
      container.read(downloadLauncherProvider) as _RecordingLauncher;

  final rows = <Widget>[];
  for (var start = 0; start < count; start += crossAxisCount) {
    rows.add(
      IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < crossAxisCount; i++)
              Expanded(
                child: start + i < count
                    ? EpisodeCard(
                        episode: episodes[start + i],
                        parentItem: item,
                      )
                    : const SizedBox.shrink(),
              ),
          ],
        ),
      ),
    );
  }

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(navigationMode: navigationMode),
            child: Directionality(
              textDirection: textDirection,
              child: Scaffold(
                body: Column(mainAxisSize: MainAxisSize.min, children: rows),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return _Harness(launcher, container);
}

void main() {
  group('EpisodeCard download action reachability', () {
    // A 1080p television reports 960x540 dp; a landscape tablet and any wide
    // desktop window clear the same 900 dp breakpoint the old
    // `if (context.isDesktop) return ExcludeFocus(child: raw)` fired on.
    for (final surface
        in const <({String name, Size size, NavigationMode mode})>[
          (
            name: 'a 960 dp television driven by a remote',
            size: Size(960, 540),
            mode: NavigationMode.directional,
          ),
          (
            name: 'a 1400 dp desktop window',
            size: Size(1400, 900),
            mode: NavigationMode.traditional,
          ),
          (
            name: 'a 400 dp handset',
            size: Size(400, 800),
            mode: NavigationMode.traditional,
          ),
        ]) {
      testWidgets('RIGHT from the episode body reaches the download button on '
          '${surface.name}', (tester) async {
        await _pumpCards(
          tester,
          logicalSize: surface.size,
          navigationMode: surface.mode,
        );

        _bodyNode(tester, 0).requestFocus();
        await tester.pump();
        expect(_downloadFocused(tester, 0), isFalse);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();

        expect(
          _downloadFocused(tester, 0),
          isTrue,
          reason: 'the download button must be a directional-input target',
        );
      });
    }

    testWidgets('in a right-to-left locale the button is reached with LEFT', (
      tester,
    ) async {
      // The action sits at the row's END, so in Hebrew or Arabic it is on the
      // left and the inward key is LEFT. Nothing in the card names an arrow:
      // the direction falls out of where the two rects are.
      await _pumpCards(tester, textDirection: TextDirection.rtl);

      _bodyNode(tester, 0).requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();

      expect(_downloadFocused(tester, 0), isTrue);
    });

    testWidgets('Tab from the episode body reaches the download button on a '
        'television', (tester) async {
      await _pumpCards(tester);

      _bodyNode(tester, 0).requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(_downloadFocused(tester, 0), isTrue);
    });

    testWidgets('LEFT returns to the body, and RIGHT reaches the button again '
        '- the card is one stop, not two', (tester) async {
      // The card must offer the body and the button and nothing else: a
      // wrapper node that swallowed LEFT would strand the viewer on the icon,
      // because directional traversal can never descend from a rect back into
      // a rect it already encloses.
      await _pumpCards(tester);

      _bodyNode(tester, 0).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_downloadFocused(tester, 0), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(
        _bodyNode(tester, 0).hasPrimaryFocus,
        isTrue,
        reason: 'LEFT must land on the body itself, not on a wrapper node',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_downloadFocused(tester, 0), isTrue);
    });

    testWidgets('DOWN from the download button lands on the next episode, not '
        "on that episode's download button", (tester) async {
      // Also the guard on the card-wide InkWell's own focus node.
      // `canRequestFocus: false` is ignored by InkResponse under
      // NavigationMode.directional - i.e. on a television - so without a
      // skipTraversal node the InkWell is a focusable box the size of the
      // card, and DOWN lands on that instead of on the next episode's body.
      await _pumpCards(tester, count: 3);

      _bodyNode(tester, 0).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_downloadFocused(tester, 0), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();

      expect(_downloadFocused(tester, 1), isFalse);
      expect(_bodyNode(tester, 1).hasPrimaryFocus, isTrue);
    });

    testWidgets('in the two-column grid a television lays out, LEFT lands on '
        "the neighbouring episode, not on its download button", (tester) async {
      await _pumpCards(tester, count: 2, crossAxisCount: 2);

      _bodyNode(tester, 1).requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();

      expect(_downloadFocused(tester, 0), isFalse);
      expect(_bodyNode(tester, 0).hasPrimaryFocus, isTrue);
    });
  });

  group('EpisodeCard download action activation', () {
    testWidgets('OK on the focused download button downloads and does not '
        'play the episode', (tester) async {
      final harness = await _pumpCards(tester);

      _bodyNode(tester, 0).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_downloadFocused(tester, 0), isTrue);

      // LogicalKeyboardKey.select is a TV remote's OK.
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();

      expect(harness.launcher.launched, <String>[_episode(1).url]);
      expect(_FakeDetailsController.played, isEmpty);
    });

    testWidgets('holding OK on the download button downloads ONCE, and a tap '
        'still downloads', (tester) async {
      final harness = await _pumpCards(tester);

      _bodyNode(tester, 0).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      // A remote repeats OK while it is held. Flutter's default
      // `SingleActivator` fires on every repeat, so leaving activation to
      // `ActivateIntent` would stack a resolve dialog per repeat.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(harness.launcher.launched, <String>[_episode(1).url]);

      await tester.tap(find.byIcon(Icons.file_download_outlined).first);
      await tester.pump();
      expect(harness.launcher.launched, <String>[
        _episode(1).url,
        _episode(1).url,
      ]);
      expect(_FakeDetailsController.played, isEmpty);
    });

    testWidgets('the body keeps its own contract: a short OK plays, a held OK '
        'selects', (tester) async {
      // The body is a bare Focus inside the card's InkWell, so an unhandled
      // OK would reach that InkWell's ActivateIntent action and play the
      // episode - including on every repeat tick of a held press, where the
      // card owes the viewer a selection toggle instead.
      await _pumpCards(tester);

      _bodyNode(tester, 0).requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(_FakeDetailsController.played, <String>[_episode(1).url]);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pump();

      expect(_FakeDetailsController.played, <String>[
        _episode(1).url,
      ], reason: 'a held OK must not play the episode again');
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    });
  });
}
