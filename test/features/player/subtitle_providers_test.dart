/// What the three subtitle providers put on the wire for one search target,
/// pinned through a stubbed Dio adapter (no sockets).
///
/// The notifier's fallback chain relies on each provider preferring an id
/// over the title and on SubSource filtering by episode client-side; these
/// are the facts it relies on.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/data/subtitle_providers.dart';

/// The provider no longer carries a baked-in key (it was a literal in a public
/// repo), so a test that wants to see the wire format has to supply one.
const String _kTestKey = 'test-api-key';

/// Answers every request from [respond] and records what was asked.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.respond);

  final Object? Function(RequestOptions request) respond;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(respond(options)),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

(Dio, _StubAdapter) _dio(Object? Function(RequestOptions request) respond) {
  final adapter = _StubAdapter(respond);
  final dio = Dio()..httpClientAdapter = adapter;
  return (dio, adapter);
}

Map<String, Object?> _osResult(String release) => {
  'id': '1',
  'attributes': {
    'release': release,
    'language': 'en',
    'hearing_impaired': false,
    'files': [
      {'file_id': 11},
    ],
  },
};

void main() {

  group('OpenSubtitles without a key', () {
    // The key used to be a literal in the source of a public repository. It is
    // now a --dart-define, so a build that supplies neither it nor a viewer key
    // must return nothing rather than firing a request with an empty Api-Key
    // header and reporting the 401 as a search failure.
    test('returns nothing instead of searching', () async {
      final dio = Dio();
      var called = false;
      dio.httpClientAdapter = _RecordingAdapter(() => called = true);
      final provider = OpenSubtitlesProvider(dio);

      final results = await provider.search(query: 'The Matrix');

      expect(results, isEmpty);
      expect(called, isFalse, reason: 'no key means no request at all');
    });
  });
  group('OpenSubtitles', () {
    test(
      'sends imdb_id without tt plus season_number/episode_number',
      () async {
        final (dio, adapter) = _dio(
          (_) => {
            'data': [_osResult('Show.S02E05.720p')],
          },
        );
        final results = await OpenSubtitlesProvider(dio, apiKey: _kTestKey).search(
          query: 'The Show',
          imdbId: 'tt0903747',
          tmdbId: 1396,
          season: 2,
          episode: 5,
          language: 'en',
        );

        final request = adapter.requests.single;
        expect(request.uri.path, endsWith('/subtitles'));
        final q = request.uri.queryParameters;
        expect(q['imdb_id'], '0903747');
        expect(q['season_number'], '2');
        expect(q['episode_number'], '5');
        expect(q['languages'], 'en');
        expect(q, isNot(contains('tmdb_id')), reason: 'imdb beats tmdb');
        expect(q, isNot(contains('query')), reason: 'imdb beats title');
        expect(results.single.name, 'Show.S02E05.720p');
        expect(results.single.metadata?['file_id'], 11);
      },
    );

    test('tmdb_id when there is no imdb id; query only when neither', () async {
      final (dio, adapter) = _dio((_) => {'data': <Object>[]});
      final provider = OpenSubtitlesProvider(dio, apiKey: _kTestKey);

      await provider.search(query: 'The Show', tmdbId: 1396);
      expect(adapter.requests.last.uri.queryParameters['tmdb_id'], '1396');
      expect(
        adapter.requests.last.uri.queryParameters,
        isNot(contains('query')),
      );

      await provider.search(query: 'The Show');
      expect(adapter.requests.last.uri.queryParameters['query'], 'The Show');
      expect(
        adapter.requests.last.uri.queryParameters,
        isNot(contains('imdb_id')),
      );
    });

    test('no season/episode -> no season_number/episode_number', () async {
      final (dio, adapter) = _dio((_) => {'data': <Object>[]});
      await OpenSubtitlesProvider(dio, apiKey: _kTestKey).search(query: 'Film', imdbId: 'tt1');
      final q = adapter.requests.single.uri.queryParameters;
      expect(q, isNot(contains('season_number')));
      expect(q, isNot(contains('episode_number')));
    });
  });

  group('SubDL', () {
    test("sends a 'tt'-prefixed imdb_id plus season/episode", () async {
      final (dio, adapter) = _dio(
        (_) => {
          'status': true,
          'subtitles': [
            {
              'id': 7,
              'release_name': 'Show.S02E05',
              'language': 'en',
              'url': '/subtitle/7.zip',
              'hi': 0,
            },
          ],
        },
      );
      final results = await SubDLProvider(dio, apiKey: 'key').search(
        query: 'The Show',
        imdbId: '0903747',
        tmdbId: 1396,
        season: 2,
        episode: 5,
        language: 'en',
      );

      final q = adapter.requests.single.uri.queryParameters;
      expect(q['imdb_id'], 'tt0903747');
      expect(q['season_number'], '2');
      expect(q['episode_number'], '5');
      expect(q['api_key'], 'key');
      expect(q, isNot(contains('tmdb_id')));
      expect(q, isNot(contains('film_name')));
      expect(results.single.downloadUrl, 'https://dl.subdl.com/subtitle/7.zip');
    });

    test("an already 'tt'-prefixed id is not doubled", () async {
      final (dio, adapter) = _dio(
        (_) => {'status': true, 'subtitles': <Object>[]},
      );
      await SubDLProvider(
        dio,
        apiKey: 'key',
      ).search(query: 'x', imdbId: 'tt0903747');
      expect(
        adapter.requests.single.uri.queryParameters['imdb_id'],
        'tt0903747',
      );
    });

    test(
      'without an API key it returns [] and never hits the network',
      () async {
        final (dio, adapter) = _dio(
          (_) => {'status': true, 'subtitles': <Object>[]},
        );
        final results = await SubDLProvider(
          dio,
        ).search(query: 'x', imdbId: 'tt0903747');
        expect(results, isEmpty);
        expect(adapter.requests, isEmpty);
      },
    );
  });

  group('SubSource V1 (API key)', () {
    Object? respond(RequestOptions request) {
      if (request.uri.path.endsWith('/movies/search')) {
        return {
          'data': [
            {'movieId': 77, 'title': 'The Show'},
          ],
        };
      }
      if (request.uri.path.endsWith('/subtitles')) {
        return {
          'data': {
            'results': [
              {'subtitleId': 1, 'releaseInfo': 'The.Show.S02E05.1080p'},
              {'subtitleId': 2, 'releaseInfo': 'The.Show.S02E06.1080p'},
              {'subtitleId': 3, 'releaseInfo': 'The.Show.Season.2.Pack'},
              {
                'subtitleId': 4,
                'releaseInfo': ['The.Show.S02E05.WEB', 'alt'],
              },
            ],
          },
        };
      }
      fail('unexpected request ${request.uri}');
    }

    test(
      'sends searchType=imdb with a tt id and never a tmdb parameter',
      () async {
        final (dio, adapter) = _dio(respond);
        await SubSourceProvider(dio, apiKey: 'key').search(
          query: 'The Show',
          imdbId: '0903747',
          tmdbId: 1396,
          season: 2,
          episode: 5,
          language: 'en',
        );

        expect(adapter.requests, hasLength(2));
        final search = adapter.requests[0];
        expect(search.uri.path, endsWith('/movies/search'));
        expect(search.uri.queryParameters['searchType'], 'imdb');
        expect(search.uri.queryParameters['imdb'], 'tt0903747');
        expect(search.headers['X-API-Key'], 'key');

        final subs = adapter.requests[1];
        expect(subs.uri.path, endsWith('/subtitles'));
        expect(subs.uri.queryParameters['movieId'], '77');
        expect(subs.uri.queryParameters['language'], 'english');

        for (final request in adapter.requests) {
          final flat = request.uri.query.toLowerCase();
          expect(flat, isNot(contains('tmdb')), reason: request.uri.toString());
          expect(flat, isNot(contains('1396')), reason: request.uri.toString());
        }
      },
    );

    test('filters results by the E{nn} tag when episode is set', () async {
      final (dio, _) = _dio(respond);
      final results = await SubSourceProvider(
        dio,
        apiKey: 'key',
      ).search(query: 'The Show', imdbId: 'tt0903747', season: 2, episode: 5);
      expect(results.map((s) => s.id), ['1', '4']);
      expect(results.first.metadata?['mode'], 'v1');
      expect(
        results.first.downloadUrl,
        'https://api.subsource.net/api/v1/subtitles/1/download',
      );
    });

    test('episode null (season-only pass) keeps every result', () async {
      final (dio, _) = _dio(respond);
      final results = await SubSourceProvider(
        dio,
        apiKey: 'key',
      ).search(query: 'The Show', imdbId: 'tt0903747', season: 2);
      expect(results.map((s) => s.id), ['1', '2', '3', '4']);
    });

    test('episode 0 is "unknown" and does not filter', () async {
      final (dio, _) = _dio(respond);
      final results = await SubSourceProvider(
        dio,
        apiKey: 'key',
      ).search(query: 'The Show', imdbId: 'tt0903747', season: 0, episode: 0);
      expect(results, hasLength(4));
    });

    // V1's /subtitles takes movieId + language only, so one multi-season show
    // comes back as a single list of every season. Matching E{nn} alone would
    // hand S01E05 and S03E05 to a viewer watching S02E05.
    Object? respondMultiSeason(RequestOptions request) {
      if (request.uri.path.endsWith('/movies/search')) {
        return {
          'data': [
            {'movieId': 77, 'title': 'The Show'},
          ],
        };
      }
      if (request.uri.path.endsWith('/subtitles')) {
        return {
          'data': {
            'results': [
              {'subtitleId': 1, 'releaseInfo': 'The.Show.S01E05.1080p'},
              {'subtitleId': 2, 'releaseInfo': 'The.Show.S02E05.1080p'},
              {'subtitleId': 3, 'releaseInfo': 'The.Show.S03E05.1080p'},
              {'subtitleId': 4, 'releaseInfo': 'The.Show.E05.720p'},
              {'subtitleId': 5, 'releaseInfo': 'The.Show.Season.1.Pack'},
              {'subtitleId': 6},
            ],
          },
        };
      }
      fail('unexpected request ${request.uri}');
    }

    test('the E{nn} filter is scoped to the season, not just the '
        'episode', () async {
      final (dio, _) = _dio(respondMultiSeason);
      final results = await SubSourceProvider(
        dio,
        apiKey: 'key',
      ).search(query: 'The Show', imdbId: 'tt0903747', season: 2, episode: 5);
      // Only S02E05. Never S01E05/S03E05, and never the season-less E05,
      // which cannot be proven to be this season.
      expect(results.map((s) => s.id), ['2']);
    });

    test('the season-only pass drops other seasons but keeps untagged '
        'entries', () async {
      final (dio, _) = _dio(respondMultiSeason);
      final results = await SubSourceProvider(
        dio,
        apiKey: 'key',
      ).search(query: 'The Show', imdbId: 'tt0903747', season: 2);
      // '2' is S02; '4' (E05, no season) and '6' (no release name at all)
      // declare no season, so the fallback pass still surfaces them.
      // '1'/'3'/'5' positively declare another season.
      expect(results.map((s) => s.id), ['2', '4', '6']);
    });

    test('a tmdb-only target is a title search (searchType=text)', () async {
      final (dio, adapter) = _dio(respond);
      await SubSourceProvider(
        dio,
        apiKey: 'key',
      ).search(query: 'The Show', tmdbId: 1396);
      final search = adapter.requests.first;
      expect(search.uri.queryParameters['searchType'], 'text');
      expect(search.uri.queryParameters['q'], 'The Show');
      expect(search.uri.queryParameters, isNot(contains('imdb')));
    });
  });

  group('SubSource keyless', () {
    Object? respond(RequestOptions request) {
      if (request.uri.path.endsWith('/searchMovie')) {
        return {
          'success': true,
          'found': [
            {'linkName': 'the-show'},
          ],
        };
      }
      if (request.uri.path.endsWith('/getMovie')) {
        return {
          'success': true,
          'subs': [
            {'subId': 1, 'lang': 'English', 'releaseName': 'The.Show.S02E05'},
            {'subId': 2, 'lang': 'English', 'releaseName': 'The.Show.S02E06'},
            {'subId': 3, 'lang': 'Hindi', 'releaseName': 'The.Show.S02E05'},
          ],
        };
      }
      fail('unexpected request ${request.uri}');
    }

    test(
      'posts the tt id, scopes to the season and filters E{nn} + language',
      () async {
        final (dio, adapter) = _dio(respond);
        final results = await SubSourceProvider(dio).search(
          query: 'The Show',
          imdbId: '0903747',
          tmdbId: 1396,
          season: 2,
          episode: 5,
          language: 'en',
        );

        expect(adapter.requests, hasLength(2));
        expect(
          (adapter.requests[0].data as Map<String, dynamic>)['query'],
          'tt0903747',
        );
        final movie = adapter.requests[1].data as Map<String, dynamic>;
        expect(movie['season'], 'season-2');
        expect(movie.values.map((v) => v.toString()), isNot(contains('1396')));
        expect(results.map((s) => s.id), ['1']);
        expect(results.single.metadata?['mode'], 'keyless');
      },
    );

    test('episode null keeps every episode in the language', () async {
      final (dio, _) = _dio(respond);
      final results = await SubSourceProvider(dio).search(
        query: 'The Show',
        imdbId: 'tt0903747',
        season: 2,
        language: 'en',
      );
      expect(results.map((s) => s.id), ['1', '2']);
    });
  });
}

/// Fails the test if any request is actually dispatched.
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.onCall);
  final void Function() onCall;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    onCall();
    return ResponseBody.fromString('{}', 200);
  }
}
