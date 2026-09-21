import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/services/tmdb_service.dart';
import '../../explore/data/explore_tmdb_provider.dart';

part 'metadata_resolution_service.g.dart';

/// How alike the two titles have to be before a TMDB result is accepted as
/// this item's identity.
///
/// Tuned so a scraper title that still carries a little junk after
/// [MetadataResolutionService.titleTokens] clears it, while an unrelated film
/// does not. Raise it and legitimate matches start being dropped; lower it
/// and the wrong-film bug this replaced comes back.
const double kTitleMatchThreshold = 0.6;

class MetadataResolutionService {
  final TmdbService _tmdbService;

  MetadataResolutionService(this._tmdbService);

  Future<MultimediaItem> enrichWithIds(MultimediaItem item) async {
    // If it already has both, skip
    if (item.tmdbId != null && item.imdbId != null) {
      if (kDebugMode) {
        debugPrint(
          'MetadataResolutionService: Both tmdbId (${item.tmdbId}) and imdbId (${item.imdbId}) already present for ${item.title}. Skipping resolution.',
        );
      }
      return item;
    }

    // We only resolve if we have a title
    if (item.title.isEmpty) {
      if (kDebugMode) {
        debugPrint(
          'MetadataResolutionService: Title is empty. Cannot resolve IDs.',
        );
      }
      return item;
    }

    if (kDebugMode) {
      debugPrint(
        'MetadataResolutionService: Resolving IDs for ${item.title}. Current tmdbId: ${item.tmdbId}, imdbId: ${item.imdbId}',
      );
    }

    // Fast path: If we already have tmdbId, just fetch the extra details to get imdbId
    if (item.tmdbId != null && item.imdbId == null) {
      if (kDebugMode) {
        debugPrint(
          'MetadataResolutionService: We have tmdbId (${item.tmdbId}), skipping multiSearch. Fetching extra details directly.',
        );
      }
      String? imdbId;
      if (item.contentType == MultimediaContentType.movie) {
        final extra = await _tmdbService.getMovieExtra(item.tmdbId!);
        if (extra != null) {
          imdbId = _extractImdbId(extra);
        }
      } else {
        final extra = await _tmdbService.getTvExtra(item.tmdbId!);
        if (extra != null) {
          imdbId = _extractImdbId(extra);
        }
      }

      final enriched = item.copyWith(imdbId: imdbId ?? item.imdbId);
      if (kDebugMode) {
        debugPrint(
          'MetadataResolutionService: Fast path resolution complete. Final item: tmdbId: ${enriched.tmdbId}, imdbId: ${enriched.imdbId}',
        );
      }
      return enriched;
    }

    // Use TMDB multiSearch
    // We can append year to the query so the regex in multiSearch picks it up
    String query = item.title;
    if (item.year != null) {
      query += ' ${item.year}';
    }

    final results = await _tmdbService.multiSearch(query: query);

    if (kDebugMode) {
      debugPrint(
        'MetadataResolutionService: multiSearch returned ${results.length} results.',
      );
    }

    if (results.isNotEmpty) {
      final bestMatch = _findBestMatch(item, results);
      if (bestMatch != null) {
        if (kDebugMode) {
          debugPrint(
            'MetadataResolutionService: Found best match: ${bestMatch.title} (tmdbId: ${bestMatch.tmdbId}, imdbId: ${bestMatch.imdbId})',
          );
        }
        String? imdbId = bestMatch.imdbId;
        final int? tmdbId = bestMatch.tmdbId;

        if (tmdbId != null && imdbId == null) {
          if (kDebugMode) {
            debugPrint(
              'MetadataResolutionService: imdbId is missing, fetching extra details for tmdbId: $tmdbId (type: ${bestMatch.contentType})',
            );
          }
          if (bestMatch.contentType == MultimediaContentType.movie) {
            final extra = await _tmdbService.getMovieExtra(tmdbId);
            if (extra != null) {
              imdbId = _extractImdbId(extra);
            }
          } else {
            final extra = await _tmdbService.getTvExtra(tmdbId);
            if (extra != null) {
              imdbId = _extractImdbId(extra);
            }
          }
          if (kDebugMode) {
            debugPrint(
              'MetadataResolutionService: Fetched extra details. Found imdbId: $imdbId',
            );
          }
        }

        final enriched = item.copyWith(
          tmdbId: tmdbId ?? item.tmdbId,
          imdbId: imdbId ?? item.imdbId,
        );
        if (kDebugMode) {
          debugPrint(
            'MetadataResolutionService: Resolution complete. Final item: tmdbId: ${enriched.tmdbId}, imdbId: ${enriched.imdbId}',
          );
        }
        return enriched;
      } else {
        if (kDebugMode) {
          debugPrint(
            'MetadataResolutionService: Could not find a best match among the results.',
          );
        }
      }
    } else {
      if (kDebugMode) {
        debugPrint(
          'MetadataResolutionService: No results found for query: $query',
        );
      }
    }

    return item;
  }

  String? _extractImdbId(Map<String, dynamic> json) {
    String? imdbId = json['imdb_id'] as String?;
    if (imdbId == null || imdbId.isEmpty) {
      final externalIds = json['external_ids'] as Map<String, dynamic>?;
      if (externalIds != null) {
        imdbId = externalIds['imdb_id'] as String?;
      }
    }
    return imdbId;
  }

  MultimediaItem? _findBestMatch(
    MultimediaItem source,
    List<MultimediaItem> results,
  ) => findBestMatch(source, results);

  /// The TMDB result that is actually this title, or null when none is close
  /// enough.
  ///
  /// This used to end in `return results.first`, unconditionally. A scraper
  /// title carries release junk - "Some Film (2024) Hindi Dubbed 720p WEB-DL"
  /// - so the exact-title branch above it almost never hit, and the search
  /// query was junk too; the fallback then adopted TMDB's first hit for a
  /// nonsense query as this film's identity.
  ///
  /// A wrong id is worse than no id. It is handed to the source scrapers and
  /// to the Trakt / Simkl / AniList scrobble, so the user is offered another
  /// film's streams and has another film marked watched - silently, because
  /// nothing downstream can tell a resolved id from a guessed one. Returning
  /// null simply leaves the item unresolved, which every caller already
  /// handles.
  @visibleForTesting
  static MultimediaItem? findBestMatch(
    MultimediaItem source,
    List<MultimediaItem> results,
  ) {
    MultimediaItem? best;
    var bestScore = 0.0;

    for (final candidate in results) {
      final score = matchScore(
        sourceTitle: source.title,
        sourceYear: source.year,
        candidate: candidate,
      );
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }

    if (best == null || bestScore < kTitleMatchThreshold) {
      if (kDebugMode) {
        debugPrint(
          'MetadataResolutionService: no candidate cleared the match '
          'threshold (best was ${best?.title} at '
          '${bestScore.toStringAsFixed(2)}); leaving the item unresolved.',
        );
      }
      return null;
    }

    if (kDebugMode) {
      debugPrint(
        'MetadataResolutionService: matched "${best.title}" at '
        '${bestScore.toStringAsFixed(2)}.',
      );
    }
    return best;
  }

  /// How alike two titles are, from 0 (nothing in common) to 1.
  @visibleForTesting
  static double matchScore({
    required String sourceTitle,
    required int? sourceYear,
    required MultimediaItem candidate,
  }) {
    // Cleaned words, falling back to the raw ones only for a title that
    // cleaning erased completely.
    //
    // Cleaning is what lets "Ghillie Dhu 720p WEB-DL x264" reach "Ghillie
    // Dhu": raw, the release junk drags that pair down to 0.46 and it is
    // refused. But cleaning alone destroys real titles - "Cam", "Dual" and
    // "Proper" are entirely release vocabulary, "1917" and "2012" are
    // entirely year - and all five reduce to nothing, matching no film ever
    // again.
    //
    // Per side, and only when empty. Scoring both readings and taking the
    // higher looks tidier and is wrong: two titles that share nothing but
    // their release tags then score 0.82 on the raw reading, which is the
    // bug cleaning was introduced to fix.
    var score = _dice(_tokensFor(sourceTitle), _tokensFor(candidate.title));
    if (score == 0) return 0;

    final candidateYear = candidate.year;
    if (sourceYear != null && candidateYear != null) {
      // Graduated, not a cliff. A scraper often reports the LOCAL release
      // year, which for an international title lags the original by a year
      // or three - penalising that as hard as a remake would throw away
      // correct matches. Past that, the same words in a different decade
      // usually are a different film, and the penalty has to be big enough
      // to sink even a perfect title: 1.00 - 0.45 falls under the threshold,
      // 1.00 - 0.30 did not, which is how "Dune" (2021) matched Lynch's.
      final drift = (sourceYear - candidateYear).abs();
      if (drift == 0) {
        score += 0.15;
      } else if (drift == 1) {
        score += 0.05;
      } else if (drift <= 3) {
        score -= 0.15;
      } else {
        score -= 0.45;
      }
    }

    return score.clamp(0.0, 1.0);
  }

  /// Twice the overlap over the combined size. Symmetric, and it punishes a
  /// candidate much longer or shorter than the source rather than rewarding
  /// a short title for being a subset of everything.
  static double _dice(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final shared = a.intersection(b).length;
    if (shared == 0) return 0;
    return (2 * shared) / (a.length + b.length);
  }

  /// The words to score a title on: the cleaned ones, or the raw ones when
  /// cleaning left nothing behind.
  static Set<String> _tokensFor(String title) {
    final cleaned = titleTokens(title);
    return cleaned.isNotEmpty ? cleaned : _rawTokens(title);
  }

  /// Every word of a title, cleaned of punctuation but nothing else.
  static Set<String> _rawTokens(String title) {
    return title
        .toLowerCase()
        .replaceAll('&', ' and ')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .split(' ')
        .where((t) => t.isNotEmpty)
        .toSet();
  }

  /// The meaningful words of a title, with release junk removed.
  @visibleForTesting
  static Set<String> titleTokens(String title) {
    var text = title.toLowerCase();

    // Bracketed groups are almost always annotations, never the title.
    text = text.replaceAll(RegExp(r'[\(\[\{][^\)\]\}]*[\)\]\}]'), ' ');
    // Season / episode markers, which TMDB titles never carry.
    text = text.replaceAll(
      RegExp(r'\bs\d{1,2}\s*e\d{1,3}\b|\b(season|episode|ep)\s*\d{1,3}\b'),
      ' ',
    );
    text = text.replaceAll('&', ' and ');
    // Everything that is not a letter or a digit is a separator.
    text = text.replaceAll(RegExp(r'[^a-z0-9]+'), ' ');

    return text
        .split(' ')
        .where((t) => t.isNotEmpty && !_junkTokens.contains(t))
        // A bare year is an annotation on the scraper's side and is compared
        // separately, so it must not prop up the word score.
        .where((t) => !RegExp(r'^(19|20)\d{2}$').hasMatch(t))
        .toSet();
  }

  /// Release-tagging vocabulary: resolution, source, codec, audio and
  /// subtitle markers that a scraper appends and TMDB never carries.
  ///
  /// Deliberately technical only. Ordinary words are left alone, because
  /// "Scary Movie" and "The Post" are real titles and stripping their words
  /// would make them match nothing.
  static const Set<String> _junkTokens = {
    '360p',
    '480p',
    '540p',
    '720p',
    '1080p',
    '1440p',
    '2160p',
    '4k',
    '8k',
    'hd',
    'fhd',
    'uhd',
    'sd',
    'hq',
    'hdr',
    'hdr10',
    'sdr',
    'dv',
    'webrip',
    'webdl',
    'web',
    'dl',
    'bluray',
    'bdrip',
    'brrip',
    'dvdrip',
    'dvdscr',
    'hdrip',
    'hdtv',
    'hdcam',
    'camrip',
    'cam',
    'ts',
    'tc',
    'predvd',
    'rip',
    'remux',
    'proper',
    'repack',
    'x264',
    'x265',
    'h264',
    'h265',
    'hevc',
    'avc',
    'xvid',
    'divx',
    'aac',
    'ac3',
    'dts',
    'ddp',
    'dd',
    'eac3',
    'atmos',
    'truehd',
    '10bit',
    '8bit',
    'bit',
    'hindi',
    'english',
    'tamil',
    'telugu',
    'malayalam',
    'kannada',
    'bengali',
    'marathi',
    'punjabi',
    'urdu',
    'korean',
    'japanese',
    'chinese',
    'spanish',
    'french',
    'german',
    'russian',
    'arabic',
    'dual',
    'multi',
    'audio',
    'dubbed',
    'dub',
    'subbed',
    'sub',
    'subs',
    'esub',
    'esubs',
    'msub',
    'msubs',
    'org',
    'line',
    'download',
    'watch',
    'online',
    'free',
    'full',
    'complete',
    'uncut',
    'extended',
    'remastered',
    'unrated',
    'directors',
    'mb',
    'gb',
  };
}

@riverpod
MetadataResolutionService metadataResolutionService(Ref ref) {
  final tmdbService = ref.watch(tmdbServiceProvider);
  return MetadataResolutionService(tmdbService);
}
