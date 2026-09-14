/// What an online subtitle search is about.
///
/// One value object instead of five loose parameters, so every hop between
/// the screen, the panel, the sheet and the notifier changes by one field.
/// Pure Dart on purpose: no Flutter, no engine, no providers.
library;

import '../../../core/domain/entity/multimedia_item.dart';

/// The title (and, when known, the ids and episode) to search subtitles for.
///
/// Every provider prefers an id over the title when one is present
/// (`subtitle_providers.dart`), so the ids here decide whether the first pass
/// is an exact-match search or a text search; see `SubtitleSearchMode`.
///
/// Not annotated `@immutable` because `package:meta` is not a declared
/// dependency and this file imports nothing from Flutter.
class SubtitleSearchTarget {
  const SubtitleSearchTarget({
    required this.title,
    this.imdbId,
    this.tmdbId,
    this.season,
    this.episode,
  });

  /// Builds the target for [item], scoped to [episode] when one is playing.
  ///
  /// The IMDb id is read from `item.imdbId`, then `syncData['imdbId']`, then
  /// `syncData['imdb_id']`, and normalised to a `tt` prefix so every provider
  /// sees the same shape.
  ///
  /// A null [episode] drops season/episode, because a hand-picked torrent pack
  /// file may not be the episode the screen thinks is playing. Zero
  /// season/episode - the `Episode` defaults - are "unknown" and become null
  /// too. Title is always the bare show title: providers that take
  /// season_number / episode_number need it, not "Show S02E05".
  factory SubtitleSearchTarget.of(MultimediaItem item, Episode? episode) {
    final season = episode?.season ?? 0;
    final number = episode?.episode ?? 0;
    return SubtitleSearchTarget(
      title: item.title,
      imdbId: normalizeImdbId(
        item.imdbId ?? item.syncData?['imdbId'] ?? item.syncData?['imdb_id'],
      ),
      tmdbId: item.tmdbId,
      season: season > 0 ? season : null,
      episode: number > 0 ? number : null,
    );
  }

  /// Bare show / film title, never decorated with season or episode.
  final String title;

  /// IMDb id with its `tt` prefix, or null when the title has none.
  final String? imdbId;

  /// TMDb numeric id, or null. Note SubSource has no TMDb parameter, so a
  /// TMDb-only target is a title search there.
  final int? tmdbId;

  /// 1-based season, or null for films and unknown episodes.
  final int? season;

  /// 1-based episode within [season], or null.
  final int? episode;

  /// True when at least one provider can do an exact-match search.
  bool get hasId => imdbId != null || tmdbId != null;

  /// True when both [season] and [episode] are known.
  bool get hasEpisode => season != null && episode != null;

  /// `'0111161'` -> `'tt0111161'`; `'tt0111161'` unchanged; blank -> null.
  static String? normalizeImdbId(String? raw) {
    final id = raw?.trim();
    if (id == null || id.isEmpty) return null;
    return id.startsWith('tt') ? id : 'tt$id';
  }

  @override
  bool operator ==(Object other) =>
      other is SubtitleSearchTarget &&
      other.title == title &&
      other.imdbId == imdbId &&
      other.tmdbId == tmdbId &&
      other.season == season &&
      other.episode == episode;

  @override
  int get hashCode => Object.hash(title, imdbId, tmdbId, season, episode);

  @override
  String toString() =>
      'SubtitleSearchTarget($title, imdb: $imdbId, tmdb: $tmdbId, '
      'S$season E$episode)';
}
