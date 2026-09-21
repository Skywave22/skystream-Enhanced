import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/details/data/metadata_resolution_service.dart';

void main() {
  MultimediaItem candidate(String title, {int? year, int? tmdbId}) {
    return MultimediaItem(
      title: title,
      url: 'tmdb:$tmdbId',
      posterUrl: '',
      year: year,
      tmdbId: tmdbId,
    );
  }

  MultimediaItem scraped(String title, {int? year}) {
    return MultimediaItem(
      title: title,
      url: 'https://example.invalid/a',
      posterUrl: '',
      year: year,
    );
  }

  // Every plugin in the catalogue that carries ids at all files them under
  // `syncData` with Stremio-style keys. Nothing read them, so the app went to
  // TMDB to guess a title it had already been told the answer for.
  group('MultimediaItem.fromJson id promotion', () {
    test('promotes tmdb and imdb ids out of syncData', () {
      final item = MultimediaItem.fromJson({
        'title': 'The Ghillie Dhu',
        'url': 'https://example.invalid/a',
        'syncData': {'tmdb': '1234', 'imdb': 'tt7654321'},
      });

      expect(item.tmdbId, 1234);
      expect(item.imdbId, 'tt7654321');
    });

    test('keeps syncData itself intact', () {
      final item = MultimediaItem.fromJson({
        'title': 'A',
        'url': 'u',
        'syncData': {'tmdb': '1234', 'anilist': '99'},
      });

      expect(item.syncData, {'tmdb': '1234', 'anilist': '99'});
    });

    test('lets a top-level id win over syncData', () {
      final item = MultimediaItem.fromJson({
        'title': 'A',
        'url': 'u',
        'tmdbId': 11,
        'imdbId': 'tt1111111',
        'syncData': {'tmdb': '22', 'imdb': 'tt2222222'},
      });

      expect(item.tmdbId, 11);
      expect(item.imdbId, 'tt1111111');
    });

    test('accepts the alternate key spellings', () {
      final item = MultimediaItem.fromJson({
        'title': 'A',
        'url': 'u',
        'syncData': {'tmdb_id': '7', 'imdb_id': 'tt0000007'},
      });

      expect(item.tmdbId, 7);
      expect(item.imdbId, 'tt0000007');
    });

    // A promoted id is treated as authoritative from then on, so a malformed
    // one has to be dropped rather than passed to the scrapers and the
    // scrobble.
    test('rejects an imdb id that is not a well-formed tt id', () {
      for (final bad in ['1234567', 'tt', 'tt123', 'nm0000123', '']) {
        final item = MultimediaItem.fromJson({
          'title': 'A',
          'url': 'u',
          'syncData': {'imdb': bad},
        });
        expect(item.imdbId, isNull, reason: 'should have rejected "$bad"');
      }
    });

    test('rejects a tmdb id that is not a positive number', () {
      for (final bad in ['abc', '0', '-5', '']) {
        final item = MultimediaItem.fromJson({
          'title': 'A',
          'url': 'u',
          'syncData': {'tmdb': bad},
        });
        expect(item.tmdbId, isNull, reason: 'should have rejected "$bad"');
      }
    });

    // Stremio-style ids carry season and episode; the title's id is the head.
    test('takes the head of a compound stremio imdb id', () {
      final item = MultimediaItem.fromJson({
        'title': 'A',
        'url': 'u',
        'syncData': {'imdb': 'tt1234567:1:2'},
      });

      expect(item.imdbId, 'tt1234567');
    });

    test('leaves both null when there is no syncData', () {
      final item = MultimediaItem.fromJson({'title': 'A', 'url': 'u'});

      expect(item.tmdbId, isNull);
      expect(item.imdbId, isNull);
    });
  });

  group('matchScore', () {
    test('scores an identical title at the ceiling', () {
      expect(
        MetadataResolutionService.matchScore(
          sourceTitle: 'The Ghillie Dhu',
          sourceYear: 2024,
          candidate: candidate('The Ghillie Dhu', year: 2024),
        ),
        1.0,
      );
    });

    test('scores an unrelated title at zero', () {
      expect(
        MetadataResolutionService.matchScore(
          sourceTitle: 'The Ghillie Dhu',
          sourceYear: 2024,
          candidate: candidate('Unsuspicious', year: 2022),
        ),
        0.0,
      );
    });

    // Raw scoring must not rescue a pair that shares no words - that would
    // undo the whole point of the threshold.
    test('stays at zero when only junk words are shared', () {
      expect(
        MetadataResolutionService.matchScore(
          sourceTitle: 'Some Film 720p WEB-DL x264',
          sourceYear: 2024,
          candidate: candidate('Other Thing 720p WEB-DL x264', year: 2024),
        ),
        lessThan(kTitleMatchThreshold),
      );
    });
  });

  group('titleTokens', () {
    test('strips release tagging', () {
      expect(
        MetadataResolutionService.titleTokens(
          'The Ghillie Dhu (2024) Hindi Dubbed 720p WEB-DL x264 ESubs',
        ),
        {'the', 'ghillie', 'dhu'},
      );
    });

    test('strips season and episode markers', () {
      expect(MetadataResolutionService.titleTokens('Severance S02E03 1080p'), {
        'severance',
      });
      expect(
        MetadataResolutionService.titleTokens('Severance Season 2 Complete'),
        {'severance'},
      );
    });

    test('drops a bare year, which is scored separately', () {
      expect(MetadataResolutionService.titleTokens('Dune 2021'), {'dune'});
    });

    // "Scary Movie" and "The Post" are real titles; a junk list that ate
    // ordinary words would leave them matching nothing.
    test('leaves ordinary words alone', () {
      expect(MetadataResolutionService.titleTokens('Scary Movie'), {
        'scary',
        'movie',
      });
    });
  });

  group('findBestMatch', () {
    // The regression. A scraper title produced a junk query, the exact-title
    // branch missed, and `return results.first` adopted an unrelated film.
    test('rejects an unrelated first result rather than taking it', () {
      final match = MetadataResolutionService.findBestMatch(
        scraped('The Ghillie Dhu (2024) Hindi Dubbed 720p WEB-DL', year: 2024),
        [
          candidate('Unsuspicious', year: 2022, tmdbId: 111),
          candidate('Adam to Atom', year: 1952, tmdbId: 222),
        ],
      );

      expect(match, isNull);
    });

    test('finds the right film through the release tagging', () {
      final match = MetadataResolutionService.findBestMatch(
        scraped('The Ghillie Dhu (2024) Hindi Dubbed 720p WEB-DL', year: 2024),
        [
          candidate('Unsuspicious', year: 2022, tmdbId: 111),
          candidate('The Ghillie Dhu', year: 2024, tmdbId: 333),
        ],
      );

      expect(match?.tmdbId, 333);
    });

    test('is not fooled by the order results arrive in', () {
      final match = MetadataResolutionService.findBestMatch(
        scraped('Dune Part Two 2024 1080p', year: 2024),
        [
          candidate('Dune', year: 2021, tmdbId: 1),
          candidate('Dune: Part Two', year: 2024, tmdbId: 2),
        ],
      );

      expect(match?.tmdbId, 2);
    });

    // Same words, different decade: a remake, or a coincidence.
    test('penalises a candidate whose year is far off', () {
      final match = MetadataResolutionService.findBestMatch(
        scraped('Dune', year: 2021),
        [candidate('Dune', year: 1984, tmdbId: 9)],
      );

      expect(match, isNull);
    });

    test('tolerates a year that is off by one', () {
      final match = MetadataResolutionService.findBestMatch(
        scraped('Some Film', year: 2024),
        [candidate('Some Film', year: 2023, tmdbId: 5)],
      );

      expect(match?.tmdbId, 5);
    });

    // A scraper often reports the local release year, which for an
    // international title lags the original by a year or three.
    test('still matches a title whose year lags by a couple of years', () {
      final match = MetadataResolutionService.findBestMatch(
        scraped('The Ghillie Dhu', year: 2026),
        [candidate('The Ghillie Dhu', year: 2024, tmdbId: 4)],
      );

      expect(match?.tmdbId, 4);
    });

    test('matches on title alone when neither side has a year', () {
      final match = MetadataResolutionService.findBestMatch(
        scraped('The Ghillie Dhu'),
        [candidate('The Ghillie Dhu', tmdbId: 7)],
      );

      expect(match?.tmdbId, 7);
    });

    // Cleaning the title is what makes the junk case work, but cleaning
    // ALONE destroys these: "Cam", "Dual" and "Proper" are entirely release
    // vocabulary, and "1917" and "2012" are entirely year. All five used to
    // reduce to no tokens and could never resolve. They are scored on their
    // raw words instead.
    for (final title in ['Cam', 'Dual', 'Proper', '1917', '2012']) {
      test('still matches "$title", which cleans down to nothing', () {
        final match = MetadataResolutionService.findBestMatch(
          scraped(title, year: 2020),
          [candidate(title, year: 2020, tmdbId: 42)],
        );

        expect(match?.tmdbId, 42);
      });
    }

    test('returns null for an empty candidate list', () {
      expect(
        MetadataResolutionService.findBestMatch(scraped('Anything'), const []),
        isNull,
      );
    });

    test('returns null when the source title is all junk', () {
      expect(
        MetadataResolutionService.findBestMatch(scraped('720p WEB-DL x264'), [
          candidate('Some Film', tmdbId: 1),
        ]),
        isNull,
      );
    });
  });
}
