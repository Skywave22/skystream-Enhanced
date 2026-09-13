import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/network/link_probe_service.dart';
import 'package:skystream/core/nuvio/data/nuvio_stream_service.dart';
import 'package:skystream/core/nuvio/models/nuvio_models.dart';
import 'package:skystream/features/sources/presentation/plugin_sources_sheet.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// An empty source list has at least five causes and they need five different
/// answers. The sheet used to print one sentence for all of them — "No links
/// found. Verify scraper repos are installed." — which is advice for exactly
/// one, and told the other four to go and reinstall working plugins.
///
/// The scraper service already reports a [NuvioScraperStatus] per scraper, so
/// none of this is new information; it was being discarded at the last step.
void main() {
  group('sourcesEmptyReason', () {
    test('a scraper that threw is not the same as one that found nothing', () {
      expect(
        sourcesEmptyReason(
          progress: _progress([_failed('a'), _failed('b')]),
          hasRows: false,
          hasTmdbId: true,
        ),
        SourcesEmptyReason.allScrapersFailed,
      );
      expect(
        sourcesEmptyReason(
          progress: _progress([_empty('a'), _empty('b')]),
          hasRows: false,
          hasTmdbId: true,
        ),
        SourcesEmptyReason.nobodyHasIt,
      );
    });

    test('one bad scraper among good ones is its own verdict', () {
      expect(
        sourcesEmptyReason(
          progress: _progress([_failed('a'), _empty('b'), _empty('c')]),
          hasRows: false,
          hasTmdbId: true,
        ),
        SourcesEmptyReason.someScrapersFailed,
      );
    });

    test('no scrapers at all is not "this title has no sources"', () {
      expect(
        sourcesEmptyReason(
          progress: _progress(const []),
          hasRows: false,
          hasTmdbId: true,
        ),
        SourcesEmptyReason.noScrapers,
      );
    });

    test('no TMDB id never reached a scraper, so it blames neither', () {
      expect(
        sourcesEmptyReason(
          progress: _progress(const []),
          hasRows: false,
          hasTmdbId: false,
        ),
        SourcesEmptyReason.noTmdbId,
      );
    });

    test('still running outranks every verdict', () {
      expect(
        sourcesEmptyReason(
          progress: _progress([_failed('a')], loading: true),
          hasRows: false,
          hasTmdbId: true,
        ),
        SourcesEmptyReason.searching,
      );
    });

    test('links that exist but are filtered out are the filters\' fault', () {
      expect(
        sourcesEmptyReason(
          progress: _progress([_failed('a')]),
          hasRows: true,
          hasTmdbId: true,
        ),
        SourcesEmptyReason.hiddenByFilters,
      );
    });
  });

  group('the sheet says which failure happened', () {
    testWidgets('every scraper failing names the connection, not the title', (
      tester,
    ) async {
      await _pumpSheet(tester, statuses: [_failed('alpha'), _failed('beta')]);

      final AppLocalizations l10n = _l10n(tester);
      expect(find.text(l10n.sourcesEmptyAllFailed), findsOneWidget);
      // The whole point: this is NOT the message a title with no sources gets.
      expect(find.text(l10n.sourcesEmptyNothingFound), findsNothing);
      expect(l10n.sourcesEmptyAllFailed, isNot(l10n.sourcesEmptyNothingFound));
    });

    testWidgets('scrapers that all answered and had nothing say so', (
      tester,
    ) async {
      await _pumpSheet(tester, statuses: [_empty('alpha'), _empty('beta')]);

      final AppLocalizations l10n = _l10n(tester);
      expect(find.text(l10n.sourcesEmptyNothingFound), findsOneWidget);
      expect(find.text(l10n.sourcesEmptyAllFailed), findsNothing);
      expect(find.text(l10n.sourcesEmptyNoScrapers), findsNothing);
    });

    testWidgets('a partial failure counts the scrapers that broke', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        statuses: [_failed('alpha'), _empty('beta'), _empty('gamma')],
      );

      final AppLocalizations l10n = _l10n(tester);
      expect(find.text(l10n.sourcesEmptySomeFailed(1, 3)), findsOneWidget);
      expect(find.text(l10n.sourcesEmptyNothingFound), findsNothing);
    });

    testWidgets('having no scrapers is not reported as having no sources', (
      tester,
    ) async {
      await _pumpSheet(tester, statuses: const []);

      final AppLocalizations l10n = _l10n(tester);
      expect(find.text(l10n.sourcesEmptyNoScrapers), findsOneWidget);
      expect(find.text(l10n.sourcesEmptyNothingFound), findsNothing);
    });

    testWidgets('a title with no TMDB id is told that, not to reinstall', (
      tester,
    ) async {
      // No id means the scrapers were never asked - resolve() is not even
      // called - so nothing about the scrapers can be wrong.
      await _pumpSheet(tester, statuses: const [], tmdbId: null);

      final AppLocalizations l10n = _l10n(tester);
      expect(find.text(l10n.sourcesEmptyNoTmdbId), findsOneWidget);
      expect(find.text(l10n.sourcesEmptyNoScrapers), findsNothing);
    });

    testWidgets('filtering every link out still blames the filters', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        statuses: [_links('alpha', 1)],
        streams: [
          const NuvioStreamResult(
            scraperId: 'alpha',
            scraperName: 'alpha',
            title: 'Movie',
            url: 'https://cdn.test/sd.mkv',
            quality: '480p',
          ),
        ],
      );

      // 1080p+ hides the only link there is.
      await tester.tap(find.text('1080p+'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final AppLocalizations l10n = _l10n(tester);
      expect(find.text(l10n.sourcesEmptyFiltered), findsOneWidget);
      expect(find.text(l10n.sourcesEmptyNothingFound), findsNothing);
    });

    testWidgets('the six answers are six different sentences', (tester) async {
      // A distinction nobody can read is not a distinction. Guards against a
      // later edit collapsing two of these back onto one string.
      await _pumpSheet(tester, statuses: const []);
      final AppLocalizations l10n = _l10n(tester);
      final List<String> messages = <String>[
        l10n.sourcesSearching,
        l10n.sourcesEmptyFiltered,
        l10n.sourcesEmptyNoTmdbId,
        l10n.sourcesEmptyNoScrapers,
        l10n.sourcesEmptyAllFailed,
        l10n.sourcesEmptyNothingFound,
      ];
      expect(messages.toSet(), hasLength(messages.length));
    });
  });
}

NuvioProgress _progress(
  List<NuvioScraperStatus> statuses, {
  bool loading = false,
}) => NuvioProgress(
  statuses: statuses,
  completedCount: statuses.length,
  totalCount: statuses.length,
  isLoading: loading,
);

NuvioScraperStatus _failed(String name) => NuvioScraperStatus(
  scraperName: name,
  outcome: NuvioScraperOutcome.failed,
  message: 'SocketException: no route to host',
);

NuvioScraperStatus _empty(String name) => NuvioScraperStatus(
  scraperName: name,
  outcome: NuvioScraperOutcome.empty,
  message: 'no links',
);

NuvioScraperStatus _links(String name, int count) => NuvioScraperStatus(
  scraperName: name,
  outcome: NuvioScraperOutcome.links,
  linkCount: count,
);

AppLocalizations _l10n(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(PluginSourcesSheet)))!;

Future<void> _pumpSheet(
  WidgetTester tester, {
  required List<NuvioScraperStatus> statuses,
  List<NuvioStreamResult> streams = const [],
  int? tmdbId = 1234,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        nuvioStreamServiceProvider.overrideWithValue(
          _FakeNuvioService(streams: streams, statuses: statuses),
        ),
        linkProbeServiceProvider.overrideWithValue(const _FakeProbeService()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(brightness: Brightness.dark),
        home: PluginSourcesSheet(
          target: MultimediaItem(
            title: 'Test Movie',
            url: '',
            posterUrl: '',
            tmdbId: tmdbId,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Replays one settled [NuvioProgress]; the per-scraper statuses are the
/// point, so they are what the test sets.
class _FakeNuvioService implements NuvioStreamService {
  _FakeNuvioService({required this.streams, required this.statuses});

  final List<NuvioStreamResult> streams;
  final List<NuvioScraperStatus> statuses;

  @override
  Stream<NuvioProgress> resolve({
    required String tmdbId,
    required String mediaType,
    int? season,
    int? episode,
  }) async* {
    yield NuvioProgress(
      streams: streams,
      statuses: statuses,
      completedCount: statuses.length,
      totalCount: statuses.length,
    );
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeProbeService implements LinkProbeService {
  const _FakeProbeService();

  @override
  Future<LinkProbeResult> probe(String url, {Map<String, String>? headers}) =>
      Future.value(const LinkProbeResult(reachable: true));

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
