/// The online subtitle search sheet, driven the way the Subtitles tab drives
/// it: handed a [SubtitleSearchTarget] and a controller on a fake engine.
///
/// What is pinned is the hand-off - which arguments reach the providers and
/// when - not the providers themselves. The real [SubtitleSearch] notifier
/// runs, over `SubtitleSearch.debugProviders`, so the id -> title fallback
/// and the repeat-search guard are the production ones; only the download,
/// which would need Dio and a temp directory, is stubbed on a subclass.
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/entity/subtitle_model.dart';
import 'package:skystream/features/player/domain/subtitle_search_target.dart';
import 'package:skystream/features/player/presentation/subtitle_search_provider.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_subtitle_search_sheet.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import 'fake_vlc_engine.dart';

const Size _tv = Size(2560, 1440);

const SubtitleSearchTarget _episode = SubtitleSearchTarget(
  title: 'The Show',
  imdbId: 'tt0903747',
  tmdbId: 1396,
  season: 2,
  episode: 5,
);

/// The same episode as [_episode] with no ids on it - a plugin-sourced series
/// the catalogue had no IMDb/TMDb match for. Season and episode still ride
/// along, so the season widening is reachable without an id ever being sent.
const SubtitleSearchTarget _episodeNoId = SubtitleSearchTarget(
  title: 'The Show',
  season: 2,
  episode: 5,
);

const SubtitleSearchTarget _localFile = SubtitleSearchTarget(
  title: 'Home.Video.2019.mkv',
);

typedef _Call = ({
  String query,
  String? imdbId,
  int? tmdbId,
  int? season,
  int? episode,
  String? language,
});

/// Stands in for the three providers: records every `search` and answers
/// through [respond], which sees the 1-based call number.
class _RecordingProvider extends SubtitleProvider {
  @override
  String get name => 'Fake';

  @override
  String get idPrefix => 'fake';

  final List<_Call> calls = <_Call>[];

  Future<List<OnlineSubtitle>> Function(int callNumber) respond = (_) async =>
      <OnlineSubtitle>[_result('1')];

  @override
  Future<List<OnlineSubtitle>> search({
    required String query,
    String? imdbId,
    int? tmdbId,
    int? season,
    int? episode,
    String? language,
    CancelToken? cancelToken,
  }) {
    calls.add((
      query: query,
      imdbId: imdbId,
      tmdbId: tmdbId,
      season: season,
      episode: episode,
      language: language,
    ));
    return respond(calls.length);
  }

  @override
  Future<String?> getDownloadUrl(OnlineSubtitle subtitle) async => null;
}

/// The production notifier with the one method that would touch the network
/// and the file system replaced: the download either "lands" at [path] or
/// fails, and every request is recorded.
class _StubDownload extends SubtitleSearch {
  _StubDownload(this.downloads, this.path);

  final List<OnlineSubtitle> downloads;
  final String? path;

  @override
  Future<String?> downloadAndPrepare(OnlineSubtitle subtitle) async {
    downloads.add(subtitle);
    return path;
  }
}

OnlineSubtitle _result(String id) => OnlineSubtitle(
  id: id,
  name: 'The.Show.S02E05.$id.srt',
  language: 'en',
  source: 'Fake',
  downloadUrl: 'https://example.com/$id',
);

/// The widget of type [T] holding primary focus, or null.
T? _focused<T extends Widget>() => FocusManager.instance.primaryFocus?.context
    ?.findAncestorWidgetOfExactType<T>();

/// The title text of the [ListTile] holding primary focus, or null.
String? _focusedTile() => (_focused<ListTile>()?.title as Text?)?.data;

/// How many traversable focus stops sit inside [element].
int _focusStopsIn(Element element) {
  var stops = 0;
  void visit(Element child) {
    final widget = child.widget;
    if (widget is Focus && widget.canRequestFocus && !widget.skipTraversal) {
      stops++;
    }
    child.visitChildren(visit);
  }

  element.visitChildren(visit);
  return stops;
}

Future<void> _down(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
  await tester.pumpAndSettle();
}

/// The retired "no subtitle account is set up" advice, matched by what it
/// claimed rather than by an ARB key that no longer exists.
///
/// `subtitleAccountsNotConfigured` told a fresh install to go to Settings and
/// add an OpenSubtitles, SubDL or SubSource key before it could search online.
/// That was untrue on a default install - OpenSubtitles runs on the bundled
/// `_defaultApiKey` and SubSource takes a keyless path - so the call site went
/// first and the key has now followed it out of all 44 ARBs.
///
/// The three cases below exist to keep that claim out of the empty state, and
/// they still do: the matcher is the claim itself - a line naming one of the
/// three providers and sending the viewer to Settings - so re-adding the
/// advice under any key, or spelling it out inline, fails them again. The
/// matcher is itself pinned by 'the retired advice is still catchable', so it
/// cannot rot into a finder that matches nothing.
final Finder _accountAdvice = find.byWidgetPredicate(
  (Widget widget) =>
      widget is Text && _accountAdviceClaim.hasMatch(widget.data ?? ''),
  description: 'text blaming an unconfigured subtitle account',
);

final RegExp _accountAdviceClaim = RegExp(
  r'(OpenSubtitles|SubDL|SubSource)[\s\S]*Settings'
  r'|Settings[\s\S]*(OpenSubtitles|SubDL|SubSource)',
  caseSensitive: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  /// Opens the sheet over a host page the way the tracks tab does, on a fresh
  /// fake engine, and returns everything a test can observe: the provider's
  /// calls, the downloads asked for, the engine, and what the sheet popped
  /// with. [settle] false leaves an in-flight search's spinner running.
  Future<
    ({
      _RecordingProvider provider,
      List<OnlineSubtitle> downloads,
      FakeVlcEngine engine,
      List<bool?> popped,
    })
  >
  pumpSheet(
    WidgetTester tester, {
    SubtitleSearchTarget? target,
    bool isTv = true,
    PlayerSettings settings = const PlayerSettings(),
    _RecordingProvider? provider,
    String? downloadPath,
    bool settle = true,
  }) async {
    tester.view.physicalSize = _tv;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final engine = FakeVlcEngine()..install();
    addTearDown(engine.dispose);
    final controller = await engine.attach();
    addTearDown(controller.dispose);

    final recorder = provider ?? _RecordingProvider();
    SubtitleSearch.debugProviders = <SubtitleProvider>[recorder];
    addTearDown(() => SubtitleSearch.debugProviders = null);

    final downloads = <OnlineSubtitle>[];
    final popped = <bool?>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerSettingsProvider.overrideWithBuild((_, _) => settings),
          subtitleSearchProvider.overrideWith(
            () => _StubDownload(downloads, downloadPath),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: Builder(
                builder: (context) => TextButton(
                  onPressed: () => unawaited(
                    VlcSubtitleSearchSheet.show(
                      context,
                      controller,
                      target: target,
                      isTv: isTv,
                    ).then(popped.add),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      // The sheet's slide-in, then the post-frame auto-search.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }
    return (
      provider: recorder,
      downloads: downloads,
      engine: engine,
      popped: popped,
    );
  }

  group('what gets searched', () {
    testWidgets('a target with an id searches on open, ids and episode along', (
      tester,
    ) async {
      final sheet = await pumpSheet(tester, target: _episode);

      expect(sheet.provider.calls, hasLength(1), reason: 'zero presses');
      expect(sheet.provider.calls.single, (
        query: 'The Show',
        imdbId: 'tt0903747',
        tmdbId: 1396,
        season: 2,
        episode: 5,
        language: 'en',
      ));
      expect(find.text(_result('1').name), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'The Show'),
        findsOneWidget,
        reason: 'the field shows the bare title, never "Show S02E05"',
      );
    });

    testWidgets('a title-only target waits for the viewer', (tester) async {
      final sheet = await pumpSheet(tester, target: _localFile);

      expect(
        sheet.provider.calls,
        isEmpty,
        reason: 'a filename is a guess, not worth a network call per open',
      );
      expect(find.text(l10n.subtitleSearchPrompt), findsOneWidget);
      expect(find.widgetWithText(TextField, _localFile.title), findsOneWidget);

      await tester.tap(find.byTooltip(l10n.search));
      await tester.pumpAndSettle();
      expect(sheet.provider.calls.single.query, _localFile.title);
      expect(sheet.provider.calls.single.imdbId, isNull);
      expect(sheet.provider.calls.single.season, isNull);
    });

    testWidgets('editing the title drops the ids; restoring it brings them '
        'back', (tester) async {
      // The auto-search stays in flight, so the guard against repeating a
      // completed request does not swallow the restored-title press below.
      final pending = Completer<List<OnlineSubtitle>>();
      final provider = _RecordingProvider()
        ..respond = (n) => n == 1
            ? pending.future
            : Future.value(<OnlineSubtitle>[_result('$n')]);
      final sheet = await pumpSheet(
        tester,
        target: _episode,
        provider: provider,
        settle: false,
      );
      expect(sheet.provider.calls, hasLength(1));

      await tester.enterText(find.byType(TextField), 'Another Show');
      await tester.tap(find.byTooltip(l10n.search));
      await tester.pumpAndSettle();

      expect(sheet.provider.calls, hasLength(2));
      expect(sheet.provider.calls[1], (
        query: 'Another Show',
        imdbId: null,
        tmdbId: null,
        season: 2,
        episode: 5,
        language: 'en',
      ), reason: 'the viewer\'s words, not the id the providers would prefer');

      await tester.enterText(find.byType(TextField), '  The Show ');
      await tester.tap(find.byTooltip(l10n.search));
      await tester.pumpAndSettle();

      expect(sheet.provider.calls, hasLength(3));
      expect(sheet.provider.calls[2].imdbId, 'tt0903747');
      expect(sheet.provider.calls[2].tmdbId, 1396);
      expect(sheet.provider.calls[2].query, 'The Show');
    });
  });

  group('what the notes say', () {
    testWidgets(
      'an id that missed and a title that hit is said once, as text',
      (tester) async {
        final provider = _RecordingProvider()
          ..respond = (n) async => n == 1
              ? const <OnlineSubtitle>[]
              : <OnlineSubtitle>[_result('title')];
        await pumpSheet(tester, target: _episode, provider: provider);

        expect(provider.calls, hasLength(2));
        expect(provider.calls[1].imdbId, isNull);
        expect(find.text(l10n.subtitleSearchTitleFallback), findsOneWidget);
        expect(
          find.text(l10n.subtitleSearchSeasonFallback),
          findsNothing,
          reason: 'the episode still scoped the pass that hit',
        );
        expect(find.text(_result('title').name), findsOneWidget);

        // Field, search button, language row, one result: the note is none.
        expect(
          _focusStopsIn(find.byType(VlcSubtitleSearchSheet).evaluate().single),
          4,
          reason: 'the note is text a remote steps past, not a stop',
        );
        expect(_focused<IconButton>(), isNotNull);
        await _down(tester);
        expect(_focusedTile(), l10n.language);
        await _down(tester);
        expect(_focusedTile(), _result('title').name);
      },
    );

    testWidgets('a direct hit carries no note', (tester) async {
      await pumpSheet(tester, target: _episode);

      expect(find.text(l10n.subtitleSearchTitleFallback), findsNothing);
      expect(find.text(l10n.subtitleSearchSeasonFallback), findsNothing);
      expect(
        _focusStopsIn(find.byType(VlcSubtitleSearchSheet).evaluate().single),
        4,
      );
    });

    testWidgets('a season-wide list says it is the season, and never blames '
        'an ID that was never sent', (tester) async {
      // No ids on the target, so pass 1 is byTitle with the episode attached.
      // It misses, the notifier drops the episode and the whole season comes
      // back: results for S02E01..E10 against an S02E05 playback. Telling the
      // viewer "nothing matched this title's ID" is false twice over - no ID
      // was in play, and the news is that they now have to find their own
      // episode in the list or run one to nine episodes out of sync.
      final provider = _RecordingProvider()
        ..respond = (n) async => n == 1
            ? const <OnlineSubtitle>[]
            : <OnlineSubtitle>[_result('season')];
      await pumpSheet(tester, target: _episodeNoId, provider: provider);

      expect(provider.calls, isEmpty, reason: 'no id is no auto-search');
      await tester.tap(find.byTooltip(l10n.search));
      await tester.pumpAndSettle();

      expect(
        provider.calls,
        hasLength(2),
        reason: 'the title, then the season',
      );
      expect(provider.calls[0].imdbId, isNull);
      expect(provider.calls[0].tmdbId, isNull);
      expect(provider.calls[0].episode, 5);
      expect(provider.calls[1].season, 2);
      expect(provider.calls[1].episode, isNull, reason: 'the episode dropped');

      expect(find.text(l10n.subtitleSearchSeasonFallback), findsOneWidget);
      expect(find.text(l10n.subtitleSearchTitleFallback), findsNothing);
      expect(find.text(_result('season').name), findsOneWidget);
      expect(
        _focusStopsIn(find.byType(VlcSubtitleSearchSheet).evaluate().single),
        4,
        reason: 'the season note is text a remote steps past, not a stop',
      );
    });

    testWidgets('an id that missed and a title that missed too still name '
        'the season, not the ID', (tester) async {
      // The full chain: byId -> byTitleAfterIdMiss -> bySeasonAfterEpisodeMiss.
      // An ID really was sent here, but it is not what the list is: these are
      // season-wide files and that is the only thing worth saying.
      final provider = _RecordingProvider()
        ..respond = (n) async => n < 3
            ? const <OnlineSubtitle>[]
            : <OnlineSubtitle>[_result('season')];
      await pumpSheet(tester, target: _episode, provider: provider);

      expect(provider.calls, hasLength(3));
      expect(provider.calls[2].episode, isNull);
      expect(find.text(l10n.subtitleSearchSeasonFallback), findsOneWidget);
      expect(find.text(l10n.subtitleSearchTitleFallback), findsNothing);
    });

    testWidgets('a fresh install with no keys says nothing was found, not '
        'that nothing is set up', (tester) async {
      // `const PlayerSettings()` is the shipping default: every key empty
      // (player_settings_provider.dart). Searching does not need one -
      // OpenSubtitles runs on the bundled `_defaultApiKey` and SubSource
      // takes its keyless path - so the search really ran, three passes
      // deep, and came back empty. Blaming the viewer's configuration for
      // that sent them out of the player to Settings for nothing and hid
      // the only advice that helps.
      //
      // The string that did the blaming is gone now, ARB key and all, so
      // these three cases match the CLAIM rather than a key - see
      // [_accountAdvice].
      final provider = _RecordingProvider()
        ..respond = (_) async => const <OnlineSubtitle>[];
      await pumpSheet(tester, target: _episode, provider: provider);

      expect(
        provider.calls,
        hasLength(3),
        reason: 'id, title, then the season: the chain ran out',
      );
      expect(find.text(l10n.noSubtitlesFoundTryAnother), findsOneWidget);
      expect(_accountAdvice, findsNothing);
    });

    testWidgets('nothing found with a key is just nothing found', (
      tester,
    ) async {
      final provider = _RecordingProvider()
        ..respond = (_) async => const <OnlineSubtitle>[];
      await pumpSheet(
        tester,
        target: _episode,
        provider: provider,
        settings: const PlayerSettings(subdlApiKey: 'k'),
      );

      expect(find.text(l10n.noSubtitlesFoundTryAnother), findsOneWidget);
      expect(_accountAdvice, findsNothing);
    });

    testWidgets('an OpenSubtitles login changes nothing about the note', (
      tester,
    ) async {
      final provider = _RecordingProvider()
        ..respond = (_) async => const <OnlineSubtitle>[];
      await pumpSheet(
        tester,
        target: _episode,
        provider: provider,
        settings: const PlayerSettings(osUsername: 'viewer'),
      );

      expect(find.text(l10n.noSubtitlesFoundTryAnother), findsOneWidget);
      expect(_accountAdvice, findsNothing);
    });

    testWidgets('the retired advice is still catchable', (tester) async {
      // A positive control for the three findsNothing above. They lost their
      // subject when `subtitleAccountsNotConfigured` was deleted from the
      // ARBs, and a finder for a string nothing renders passes for free. This
      // renders the exact wording that was retired and requires the matcher to
      // see it, so the three cases keep failing if anyone brings the claim
      // back - under a new key, or hardcoded.
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Text(
              'No subtitle account is set up. Add an OpenSubtitles, SubDL or '
              'SubSource key in Settings to search online.',
            ),
          ),
        ),
      );

      expect(_accountAdvice, findsOneWidget);
    });
  });

  group('a chosen result', () {
    testWidgets('is downloaded, handed to the engine and closes the sheet', (
      tester,
    ) async {
      final sheet = await pumpSheet(
        tester,
        target: _episode,
        downloadPath: '/tmp/subs/The.Show.S02E05.srt',
      );

      await tester.tap(find.text(_result('1').name));
      await tester.pumpAndSettle();

      expect(sheet.downloads.map((s) => s.id), <String>['1']);
      final added = sheet.engine.callsTo('addSubtitle');
      expect(added, hasLength(1));
      expect(
        (added.single.arguments as Map<Object?, Object?>)['uri'],
        Uri.file('/tmp/subs/The.Show.S02E05.srt').toString(),
      );
      expect(sheet.popped, <bool?>[true]);
      expect(find.byType(VlcSubtitleSearchSheet), findsNothing);
    });

    testWidgets('that fails to download says so and stays open', (
      tester,
    ) async {
      final sheet = await pumpSheet(tester, target: _episode);

      await tester.tap(find.text(_result('1').name));
      await tester.pumpAndSettle();

      expect(find.text(l10n.subtitleDownloadFailed), findsOneWidget);
      expect(sheet.engine.callsTo('addSubtitle'), isEmpty);
      expect(sheet.popped, isEmpty);
      expect(find.byType(VlcSubtitleSearchSheet), findsOneWidget);
    });

    testWidgets('that the engine refuses says so, stops the progress bar and '
        'leaves the list usable', (tester) async {
      final sheet = await pumpSheet(
        tester,
        target: _episode,
        downloadPath: '/tmp/subs/The.Show.S02E05.srt',
      );

      // The file downloaded fine; the *engine* said no. Every native can:
      // Android when `addSlave` returns false or the player is not active,
      // macOS/iOS on a non-zero `addPlaybackSlave` status, and the Dart side
      // on a disposed controller. It arrives as a PlatformException over the
      // same channel the fake answers on.
      final refused = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FakeVlcEngine.channel, (call) async {
            refused.add(call);
            if (call.method == 'addSubtitle') {
              throw PlatformException(
                code: 'add_subtitle_failed',
                message: 'addSlave returned false',
              );
            }
            return null;
          });

      await tester.tap(find.text(_result('1').name));
      await tester.pumpAndSettle();

      expect(refused.map((call) => call.method), contains('addSubtitle'));
      expect(find.text(l10n.subtitleDownloadFailed), findsOneWidget);
      expect(
        find.byType(LinearProgressIndicator),
        findsNothing,
        reason: 'the download is over, refused or not',
      );
      expect(sheet.popped, isEmpty);
      expect(find.byType(VlcSubtitleSearchSheet), findsOneWidget);
      expect(
        tester
            .widget<ListTile>(find.widgetWithText(ListTile, _result('1').name))
            .enabled,
        isTrue,
        reason: 'an unfocusable list on a remote has no exit but Back',
      );
    });
  });

  group('on a television', () {
    testWidgets('focus waits on the search button while results load, and '
        'DOWN reaches the first result', (tester) async {
      final pending = Completer<List<OnlineSubtitle>>();
      final provider = _RecordingProvider()..respond = (_) => pending.future;
      await pumpSheet(
        tester,
        target: _episode,
        provider: provider,
        settle: false,
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        _focused<IconButton>(),
        isNotNull,
        reason: 'a visible Retry while the network is out',
      );

      pending.complete(<OnlineSubtitle>[_result('1'), _result('2')]);
      await tester.pumpAndSettle();
      expect(_focused<IconButton>(), isNotNull, reason: 'results do not steal');

      await _down(tester);
      await _down(tester);
      expect(_focusedTile(), _result('1').name);
    });

    testWidgets('an unseeded sheet starts in the field', (tester) async {
      await pumpSheet(tester);

      expect(_focused<TextField>(), isNotNull);
    });

    testWidgets('off a television nothing is focused until asked', (
      tester,
    ) async {
      await pumpSheet(tester, target: _episode, isTv: false);

      expect(_focused<IconButton>(), isNull);
      expect(_focused<TextField>(), isNull);
    });
  });
}
