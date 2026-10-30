import 'package:html_unescape/html_unescape.dart';
import 'package:collection/collection.dart';

import '../../config/tmdb_config.dart';

enum MultimediaContentType { movie, series, anime, livestream, other }

/// A show's run. [unknown] when nothing said: no chip claims a status its
/// source never gave.
enum ShowStatus { completed, ongoing, upcoming, unknown }

enum DubStatus { none, dubbed, subbed }

class Actor {
  final String name;
  final String? image;
  final String? role;
  final Actor? voiceActor;

  /// Whether [role] is one of CloudStream's three role names (Main,
  /// Supporting, Background), which the screens translate, rather than free
  /// text an extension wrote, which they show as it is.
  final bool roleIsEnum;

  Actor({
    required this.name,
    this.image,
    this.role,
    this.voiceActor,
    this.roleIsEnum = false,
  });

  factory Actor.fromJson(Map<String, dynamic> json) {
    return Actor(
      name: (json['name'] as String?) ?? '',
      image: json['image'] as String?,
      role: (json['role'] as String?) ?? (json['roleString'] as String?),
      voiceActor: json['voiceActor'] != null
          ? Actor.fromJson(Map<String, dynamic>.from(json['voiceActor'] as Map))
          : null,
      roleIsEnum: (json['roleIsEnum'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'image': image,
      'role': role,
      'voiceActor': voiceActor?.toJson(),
      'roleIsEnum': roleIsEnum,
    };
  }
}

class Trailer {
  final String url;
  final Map<String, String>? headers;

  /// The URL is the video itself, not a page an extractor reads
  /// (CloudStream's `TrailerData.raw`).
  final bool raw;
  final String? referer;

  Trailer({required this.url, this.headers, this.raw = false, this.referer});

  factory Trailer.fromJson(Map<String, dynamic> json) {
    return Trailer(
      url: (json['url'] as String?) ?? (json['extractorUrl'] as String?) ?? '',
      headers: json['headers'] != null
          ? Map<String, String>.from(json['headers'] as Map)
          : null,
      raw: (json['raw'] as bool?) ?? false,
      referer: json['referer'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {'url': url, 'headers': headers, 'raw': raw, 'referer': referer};
  }
}

class NextAiring {
  final int episode;
  final int unixTime;
  final int? season;

  NextAiring({required this.episode, required this.unixTime, this.season});

  factory NextAiring.fromJson(Map<String, dynamic> json) {
    return NextAiring(
      episode: (json['episode'] as int?) ?? 0,
      unixTime: (json['unixTime'] as int?) ?? 0,
      season: json['season'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {'episode': episode, 'unixTime': unixTime, 'season': season};
  }
}

/// A season's own name, as an extension gives it (CloudStream's
/// `SeasonData`): shown as "Season [displaySeason]: [name]", or [name] alone
/// when there is no number to show.
class SeasonName {
  final int season;
  final String? name;
  final int? displaySeason;

  const SeasonName({required this.season, this.name, this.displaySeason});

  factory SeasonName.fromJson(Map<String, dynamic> json) => SeasonName(
    season: (json['season'] as num?)?.toInt() ?? 0,
    name: json['name'] as String?,
    displaySeason: (json['displaySeason'] as num?)?.toInt(),
  );

  Map<String, dynamic> toJson() => {
    'season': season,
    'name': name,
    'displaySeason': displaySeason,
  };
}

class MultimediaItem {
  static final _unescape = HtmlUnescape();
  final String title;
  final String url;
  final String posterUrl;
  final String? bannerUrl;
  final String? logoUrl;
  final String? description;
  final MultimediaContentType contentType;
  final List<Episode>? episodes;
  final String? provider;
  final Map<String, String>? headers;

  // New parity fields
  final int? year;
  final double? score;
  final int? duration;
  final ShowStatus status;
  final List<String>? tags;
  final String? contentRating;
  final List<Actor>? cast;
  final List<Trailer>? trailers;
  final List<MultimediaItem>? recommendations;
  final Map<String, String>? syncData;
  final String? playbackPolicy;
  final bool isAdult;
  final NextAiring? nextAiring;

  /// Not out yet: nothing to play (CloudStream's `comingSoon`).
  final bool comingSoon;

  /// The extension's own names for its seasons.
  final List<SeasonName>? seasonNames;
  final List<StreamResult>? streams;

  final int? tmdbId;
  final String? imdbId;
  final String? source;

  /// The manifest URL of the Stremio add-on that described this title, for an
  /// add-on item: Continue Watching reopens the title through it, and the
  /// player asks it for the next episode's links unless [streamAddonUrl]
  /// names another.
  final String? addonUrl;

  /// The manifest URL of the Stremio add-on whose link is playing, when one
  /// is: the player asks it for the next episode's links, as Stremio goes on
  /// with the add-on a show started on. A link picked from another add-on's
  /// (Torrentio's, for a title Cinemeta described) leaves [addonUrl] as it is.
  final String? streamAddonUrl;

  /// The type that add-on published the title as (`movie`, `series`, `other`,
  /// `tv`...). Bridges such as CNCVerse answer only on the type they published.
  final String? addonType;

  MultimediaItem({
    required this.title,
    required this.url,
    required this.posterUrl,
    this.bannerUrl,
    this.logoUrl,
    this.description,
    this.contentType = MultimediaContentType.movie,
    List<Episode>? episodes,
    this.provider,
    this.headers,
    this.year,
    this.score,
    this.duration,
    this.status = ShowStatus.unknown,
    this.tags,
    this.contentRating,
    this.cast,
    this.trailers,
    this.recommendations,
    this.syncData,
    this.playbackPolicy,
    this.isAdult = false,
    this.nextAiring,
    this.comingSoon = false,
    this.seasonNames,
    this.streams,
    this.tmdbId,
    this.imdbId,
    this.source,
    this.addonUrl,
    this.streamAddonUrl,
    this.addonType,
  }) : episodes = episodes != null
           ? (List<Episode>.from(episodes)..sort((a, b) {
               if (a.season != b.season) return a.season.compareTo(b.season);
               return a.episode.compareTo(b.episode);
             }))
           : null;

  factory MultimediaItem.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('media_type') &&
        json.containsKey('vote_average') &&
        !json.containsKey('posterUrl')) {
      return MultimediaItem.fromTmdbJson(json);
    }
    final title = json['title'] != null
        ? _unescape.convert(json['title'] as String)
        : '';

    final String? typeStr =
        (json['type'] as String?) ?? (json['contentType'] as String?);
    final MultimediaContentType type = MultimediaItem.parseContentType(typeStr);

    final Map<String, String>? syncData = json['syncData'] != null
        ? Map<String, String>.from(json['syncData'] as Map)
        : null;

    return MultimediaItem(
      title: title,
      url: (json['url'] as String?) ?? '',
      posterUrl: (json['posterUrl'] as String?) ?? '',
      bannerUrl:
          (json['backgroundPosterUrl'] as String?) ??
          (json['bannerUrl'] as String?),
      logoUrl: json['logoUrl'] as String?,
      description: json['description'] != null
          ? _unescape.convert(json['description'] as String)
          : null,
      contentType: type,
      episodes: json['episodes'] != null
          ? (json['episodes'] as List)
                .map<Episode>(
                  (e) => Episode.fromJson(Map<String, dynamic>.from(e as Map)),
                )
                .toList()
          : null,
      streams: json['streams'] != null
          ? (json['streams'] as List)
                .map<StreamResult>(
                  (s) => StreamResult.fromJson(
                    Map<String, dynamic>.from(s as Map),
                  ),
                )
                .toList()
          : null,
      provider: json['provider'] as String?,
      headers: json['headers'] != null
          ? Map<String, String>.from(json['headers'] as Map)
          : null,
      year: json['year'] as int?,
      score: (json['score'] as num?)?.toDouble(),
      duration: json['duration'] as int?,
      status: _parseShowStatus(json['status'] ?? json['showStatus']),
      tags: json['tags'] != null
          ? List<String>.from(json['tags'] as List)
          : null,
      cast: json['cast'] != null || json['actors'] != null
          ? ((json['cast'] ?? json['actors']) as List)
                .map<Actor>(
                  (a) => Actor.fromJson(Map<String, dynamic>.from(a as Map)),
                )
                .toList()
          : null,
      trailers: json['trailers'] != null
          ? (json['trailers'] as List)
                .map<Trailer>(
                  (t) => Trailer.fromJson(Map<String, dynamic>.from(t as Map)),
                )
                .toList()
          : null,
      recommendations: json['recommendations'] != null
          ? (json['recommendations'] as List)
                .map<MultimediaItem>(
                  (r) => MultimediaItem.fromJson(
                    Map<String, dynamic>.from(r as Map),
                  ),
                )
                .toList()
          : null,
      syncData: syncData,
      playbackPolicy:
          (json['playbackPolicy'] as String?) ?? (json['vpnStatus'] as String?),
      isAdult: (json['isAdult'] as bool?) ?? false,
      nextAiring: json['nextAiring'] != null
          ? NextAiring.fromJson(
              Map<String, dynamic>.from(json['nextAiring'] as Map),
            )
          : null,
      comingSoon: (json['comingSoon'] as bool?) ?? false,
      seasonNames: json['seasonNames'] != null
          ? (json['seasonNames'] as List)
                .map<SeasonName>(
                  (s) =>
                      SeasonName.fromJson(Map<String, dynamic>.from(s as Map)),
                )
                .toList()
          : null,
      // Top level first, then `syncData`.
      //
      // `syncData` is the DOCUMENTED way for a plugin to report external ids
      // - the developer guide specifies `{ mal: "123", tmdb: "456" }` and
      // describes no top-level id field at all - and every plugin in the
      // catalogue that carries ids follows it. Nothing here read them, so the
      // app behaved as though those plugins had sent nothing, went off to
      // TMDB to guess a title it had already been told the answer for, and
      // could land on a different film entirely.
      //
      // The top-level keys are kept ahead of it because items built inside
      // the app (from TMDB, from a details route) set them directly.
      tmdbId: (json['tmdbId'] as int?) ?? _syncTmdbId(syncData),
      imdbId: (json['imdbId'] as String?) ?? _syncImdbId(syncData),
      source: json['source'] as String?,
      addonUrl: json['addonUrl'] as String?,
      streamAddonUrl: json['streamAddonUrl'] as String?,
      addonType: json['addonType'] as String?,
    );
  }

  /// The TMDB id a plugin filed under `syncData`, or null.
  ///
  /// Plugins send it as a string; anything that is not a plain number is
  /// ignored rather than guessed at.
  static int? _syncTmdbId(Map<String, String>? syncData) {
    if (syncData == null) return null;
    for (final key in const ['tmdb', 'tmdbId', 'tmdb_id', 'themoviedb']) {
      final raw = syncData[key];
      if (raw == null || raw.isEmpty) continue;
      final parsed = int.tryParse(raw.trim());
      if (parsed != null && parsed > 0) return parsed;
    }
    return null;
  }

  /// The IMDb id a plugin filed under `syncData`, or null.
  ///
  /// Only a well-formed `tt` id is accepted: a malformed one would be
  /// promoted to authoritative and sent to the source scrapers and the
  /// tracking services, where a wrong id is worse than no id at all.
  static String? _syncImdbId(Map<String, String>? syncData) {
    if (syncData == null) return null;
    for (final key in const ['imdb', 'imdbId', 'imdb_id']) {
      final raw = syncData[key]?.trim();
      if (raw == null || raw.isEmpty) continue;
      // Stremio-style ids can carry a season and episode - `tt1234567:1:2` -
      // and the title's own id is the head of that. Same rule AddonMeta uses.
      final head = raw.split(':').first;
      if (RegExp(r'^tt\d{6,}$').hasMatch(head)) return head;
    }
    return null;
  }

  factory MultimediaItem.fromTmdbJson(Map<String, dynamic> json) {
    final String mTypeStr =
        (json['media_type'] as String?) ??
        (json['title'] != null ? 'movie' : 'tv');
    final title = _unescape.convert(
      (json['title'] as String?) ?? (json['name'] as String?) ?? 'Unknown',
    );
    final date =
        (json['release_date'] as String?) ??
        (json['first_air_date'] as String?) ??
        '';
    final year = int.tryParse(date.split('-').first);
    final posterPath = json['poster_path'] as String?;
    final backdropPath = json['backdrop_path'] as String?;

    // Using simple logic for now, we'll eventually use AppImageFallbacks once we unify more
    final posterUrl = posterPath != null
        ? '${TmdbConfig.posterSizeUrl}$posterPath'
        : '';
    final bannerUrl = backdropPath != null
        ? '${TmdbConfig.backdropSizeUrl}$backdropPath'
        : posterUrl;

    return MultimediaItem(
      title: title,
      url: '', // Needs detail resolving
      posterUrl: posterUrl,
      bannerUrl: bannerUrl,
      description: json['overview'] as String?,
      contentType: MultimediaItem.parseContentType(mTypeStr),
      year: year,
      score: (json['vote_average'] as num?)?.toDouble(),
      tmdbId: json['id'] as int?,
      imdbId: json['imdbId'] as String?,
    );
  }

  /// A source's word for a show's run, CloudStream's and plugins' own as well
  /// as TMDB's, MAL's and AniList's. Any other word says nothing, so no chip
  /// claims a run the source never described.
  static ShowStatus _parseShowStatus(dynamic raw) {
    if (raw == null) return ShowStatus.unknown;
    final str = raw.toString().toLowerCase();
    bool any(List<String> words) => words.any(str.contains);
    if (any(['complet', 'ended', 'finish', 'cancel'])) {
      return ShowStatus.completed;
    }
    if (any(['upcoming', 'soon', 'not yet', 'not_yet', 'planned'])) {
      return ShowStatus.upcoming;
    }
    if (any(['ongoing', 'airing', 'releasing', 'returning', 'continuing'])) {
      return ShowStatus.ongoing;
    }
    return ShowStatus.unknown;
  }

  static MultimediaContentType parseContentType(String? raw) {
    if (raw == null) return MultimediaContentType.movie;
    switch (raw.toLowerCase()) {
      case 'movie':
        return MultimediaContentType.movie;
      case 'series':
      case 'tvseries':
      case 'tv':
        return MultimediaContentType.series;
      case 'anime':
        return MultimediaContentType.anime;
      case 'livestream':
      case 'live':
      case 'iptv':
        return MultimediaContentType.livestream;
      default:
        return MultimediaContentType.other;
    }
  }

  // Compatibility getters for TmdbItem migration
  int get id => tmdbId ?? 0;
  String get mediaType {
    return contentType.name.toUpperCase();
  }

  String get tmdbMediaType =>
      contentType == MultimediaContentType.series ? 'tv' : 'movie';

  String get backdropImageUrl => bannerUrl ?? posterUrl;
  String get posterImageUrl => posterUrl;
  String get thumbnailImageUrl => posterUrl;
  String get releaseDate => year?.toString() ?? '';
  String get overview => description ?? '';
  double get voteAverage => score ?? 0.0;
  String get genresStr => tags?.join(' | ') ?? '';

  MultimediaItem copyWith({
    String? title,
    String? url,
    String? posterUrl,
    String? bannerUrl,
    String? logoUrl,
    String? description,
    MultimediaContentType? contentType,
    List<Episode>? episodes,
    String? provider,
    Map<String, String>? headers,
    int? year,
    double? score,
    int? duration,
    ShowStatus? status,
    List<String>? tags,
    String? contentRating,
    List<Actor>? cast,
    List<Trailer>? trailers,
    List<MultimediaItem>? recommendations,
    Map<String, String>? syncData,
    String? playbackPolicy,
    bool? isAdult,
    NextAiring? nextAiring,
    bool? comingSoon,
    List<SeasonName>? seasonNames,
    List<StreamResult>? streams,
    int? tmdbId,
    String? imdbId,
    String? source,
    String? addonUrl,
    String? streamAddonUrl,
    String? addonType,
  }) {
    return MultimediaItem(
      title: title ?? this.title,
      url: url ?? this.url,
      posterUrl: posterUrl ?? this.posterUrl,
      bannerUrl: bannerUrl ?? this.bannerUrl,
      logoUrl: logoUrl ?? this.logoUrl,
      description: description ?? this.description,
      contentType: contentType ?? this.contentType,
      episodes: episodes ?? this.episodes,
      provider: provider ?? this.provider,
      headers: headers ?? this.headers,
      year: year ?? this.year,
      score: score ?? this.score,
      duration: duration ?? this.duration,
      status: status ?? this.status,
      tags: tags ?? this.tags,
      contentRating: contentRating ?? this.contentRating,
      cast: cast ?? this.cast,
      trailers: trailers ?? this.trailers,
      recommendations: recommendations ?? this.recommendations,
      syncData: syncData ?? this.syncData,
      playbackPolicy: playbackPolicy ?? this.playbackPolicy,
      isAdult: isAdult ?? this.isAdult,
      nextAiring: nextAiring ?? this.nextAiring,
      comingSoon: comingSoon ?? this.comingSoon,
      seasonNames: seasonNames ?? this.seasonNames,
      streams: streams ?? this.streams,
      tmdbId: tmdbId ?? this.tmdbId,
      imdbId: imdbId ?? this.imdbId,
      source: source ?? this.source,
      addonUrl: addonUrl ?? this.addonUrl,
      streamAddonUrl: streamAddonUrl ?? this.streamAddonUrl,
      addonType: addonType ?? this.addonType,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'url': url,
      'posterUrl': posterUrl,
      'bannerUrl': bannerUrl,
      'logoUrl': logoUrl,
      'description': description,
      'type': contentType.name,
      'episodes': episodes?.map((e) => e.toJson()).toList(),
      'provider': provider,
      'headers': headers,
      'year': year,
      'score': score,
      'duration': duration,
      'status': status.name,
      'tags': tags,
      'contentRating': contentRating,
      'cast': cast?.map((a) => a.toJson()).toList(),
      'trailers': trailers?.map((t) => t.toJson()).toList(),
      'recommendations': recommendations?.map((r) => r.toJson()).toList(),
      'syncData': syncData,
      'playbackPolicy': playbackPolicy,
      'isAdult': isAdult,
      'nextAiring': nextAiring?.toJson(),
      'comingSoon': comingSoon,
      'seasonNames': seasonNames?.map((s) => s.toJson()).toList(),
      'tmdbId': tmdbId,
      'imdbId': imdbId,
      'streams': streams?.map((s) => s.toJson()).toList(),
      'source': source,
      'addonUrl': addonUrl,
      'streamAddonUrl': streamAddonUrl,
      'addonType': addonType,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MultimediaItem &&
          runtimeType == other.runtimeType &&
          url == other.url &&
          title == other.title &&
          posterUrl == other.posterUrl &&
          provider == other.provider &&
          tmdbId == other.tmdbId &&
          imdbId == other.imdbId &&
          const MapEquality<String, String>().equals(syncData, other.syncData);

  @override
  int get hashCode =>
      url.hashCode ^
      title.hashCode ^
      posterUrl.hashCode ^
      (provider?.hashCode ?? 0) ^
      (tmdbId?.hashCode ?? 0) ^
      (imdbId?.hashCode ?? 0) ^
      const MapEquality<String, String>().hash(syncData);
}

class Episode {
  static final _unescape = HtmlUnescape();
  final String name;
  final String url;
  final int season;
  final int episode;
  final String? description;
  final String? posterUrl;
  final Map<String, String>? headers;

  // Parity fields
  final double? rating;
  final int? runtime;
  final String? airDate;

  /// When it aired, or airs: CloudStream's `date`, kept in UTC. [airDate]
  /// keeps the text the player's episode list shows.
  final DateTime? airedAt;
  final DubStatus dubStatus;
  final String? playbackPolicy;
  final List<StreamResult>? streams;

  Episode({
    required this.name,
    required this.url,
    this.season = 0,
    this.episode = 0,
    this.description,
    this.posterUrl,
    this.headers,
    this.rating,
    this.runtime,
    this.airDate,
    this.airedAt,
    this.dubStatus = DubStatus.none,
    this.playbackPolicy,
    this.streams,
  });

  factory Episode.fromJson(Map<String, dynamic> json) {
    final name = json['name'] != null
        ? _unescape.convert(json['name'] as String)
        : '';
    return Episode(
      name: name,
      url: (json['url'] as String?) ?? '',
      season: (json['season'] as int?) ?? 0,
      episode: (json['episode'] as int?) ?? 0,
      description: json['description'] != null
          ? _unescape.convert(json['description'] as String)
          : null,
      posterUrl: json['posterUrl'] as String?,
      headers: json['headers'] != null
          ? Map<String, String>.from(json['headers'] as Map)
          : null,
      rating: (json['rating'] as num?)?.toDouble(),
      runtime: (json['runtime'] as int?) ?? (json['duration'] as int?),
      airDate: json['airDate'] as String?,
      airedAt: json['airedAt'] is num
          ? DateTime.fromMillisecondsSinceEpoch(
              (json['airedAt'] as num).toInt(),
              isUtc: true,
            )
          : null,
      dubStatus: _parseDubStatus(json['dubStatus']),
      playbackPolicy:
          (json['playbackPolicy'] as String?) ?? (json['vpnStatus'] as String?),
      streams: json['streams'] != null
          ? (json['streams'] as List)
                .map<StreamResult>(
                  (s) => StreamResult.fromJson(
                    Map<String, dynamic>.from(s as Map),
                  ),
                )
                .toList()
          : null,
    );
  }

  static DubStatus _parseDubStatus(dynamic raw) {
    if (raw == null) return DubStatus.none;
    if (raw is DubStatus) return raw;
    final str = raw.toString().trim().toLowerCase();
    if (str == 'dub' || str == 'dubbed') return DubStatus.dubbed;
    if (str == 'sub' || str == 'subbed') return DubStatus.subbed;
    return DubStatus.none;
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'url': url,
      'season': season,
      'episode': episode,
      'description': description,
      'posterUrl': posterUrl,
      'headers': headers,
      'rating': rating,
      'runtime': runtime,
      'airDate': airDate,
      'airedAt': airedAt?.millisecondsSinceEpoch,
      'dubStatus': dubStatus.name,
      'playbackPolicy': playbackPolicy,
      'streams': streams?.map((s) => s.toJson()).toList(),
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Episode &&
          runtimeType == other.runtimeType &&
          url == other.url &&
          season == other.season &&
          episode == other.episode;

  @override
  int get hashCode => url.hashCode ^ season.hashCode ^ episode.hashCode;
}

/// A plugin's `quality`, as a height in lines: `0` is adaptive - an HLS
/// master that offers several, which the player lists in its Quality tab.
///
/// Plugins write it as a number (`1080`) or a string: `"1080p"`, `"720"`,
/// `"4K"`/`"UHD"` (2160), `"2K"` (1440), `"Auto"` (0). Anything else is
/// ignored, and so is the number 400: CloudStream's and skystream-extractors'
/// `Qualities.Unknown`, which a plugin passing an extractor's links on hands
/// over as it is.
int? parseStreamQuality(Object? value) {
  if (value is num) {
    if (!value.isFinite) return null;
    final height = value.round();
    if (height == 0) return 0;
    if (height == _kUnknownStreamQuality) return null;
    return _plausibleHeight(height);
  }
  if (value is! String) return null;
  final text = value.trim().toLowerCase();
  if (text == 'auto') return 0;
  if (text == '4k' || text == 'uhd') return 2160;
  if (text == '2k') return 1440;
  final match = _qualityDigits.firstMatch(text);
  return match == null ? null : _plausibleHeight(int.parse(match.group(1)!));
}

/// `Qualities.Unknown` in CloudStream and skystream-extractors.
const int _kUnknownStreamQuality = 400;

final RegExp _qualityDigits = RegExp(r'^(\d{3,4})\s*p?$');

/// [height] when a picture could be that tall: 144p up to 8K.
int? _plausibleHeight(int height) =>
    height >= 144 && height <= 4320 ? height : null;

class StreamResult {
  final String url;
  final String source;

  /// The stream's height in lines, or `0` for an adaptive stream - an HLS
  /// master offering several qualities, which the player lists in its
  /// Quality tab. Null when the plugin gave none; see [parseStreamQuality].
  final int? quality;

  /// Display name of the plugin/provider that produced this stream. It is shown
  /// in the player source list and used by cross-provider source switching.
  final String providerName;
  final Map<String, String>? headers;
  final List<SubtitleFile>? subtitles;
  final String? drmKid;
  final String? drmKey;
  final String? licenseUrl;

  /// The sound of this stream, when it is in a file of its own: a CloudStream extension can
  /// give the video and the audio apart (a YouTube download does), and the player then plays
  /// the two together. Null when the stream carries its own sound.
  final String? audioUrl;

  /// The headers the [audioUrl] needs, when it needs any.
  final Map<String, String>? audioHeaders;

  const StreamResult({
    required this.url,
    required this.source,
    this.providerName = 'Unknown',
    this.quality,
    this.headers,
    this.subtitles,
    this.drmKid,
    this.drmKey,
    this.licenseUrl,
    this.audioUrl,
    this.audioHeaders,
  });

  String get displaySource =>
      providerName.trim().isEmpty ? source : '$providerName · $source';

  StreamResult copyWith({
    String? url,
    String? source,
    String? providerName,
    int? quality,
    Map<String, String>? headers,
    List<SubtitleFile>? subtitles,
    String? drmKid,
    String? drmKey,
    String? licenseUrl,
    String? audioUrl,
    Map<String, String>? audioHeaders,
  }) {
    return StreamResult(
      url: url ?? this.url,
      source: source ?? this.source,
      providerName: providerName ?? this.providerName,
      quality: quality ?? this.quality,
      headers: headers ?? this.headers,
      subtitles: subtitles ?? this.subtitles,
      drmKid: drmKid ?? this.drmKid,
      drmKey: drmKey ?? this.drmKey,
      licenseUrl: licenseUrl ?? this.licenseUrl,
      audioUrl: audioUrl ?? this.audioUrl,
      audioHeaders: audioHeaders ?? this.audioHeaders,
    );
  }

  Map<String, dynamic> toJson() => {
    'url': url,
    'source': source,
    'providerName': providerName,
    'quality': quality,
    'headers': headers,
    'subtitles': subtitles?.map((x) => x.toJson()).toList(),
    'drmKid': drmKid,
    'drmKey': drmKey,
    'licenseUrl': licenseUrl,
  };

  factory StreamResult.fromJson(Map<String, dynamic> json) {
    return StreamResult(
      url: (json['url'] as String?) ?? '',
      source: (json['source'] as String?) ?? 'Unknown',
      providerName: (json['providerName'] as String?) ?? 'Unknown',
      quality: parseStreamQuality(json['quality']),
      headers: json['headers'] != null
          ? Map<String, String>.from(json['headers'] as Map)
          : null,
      subtitles: json['subtitles'] != null
          ? (json['subtitles'] as List)
                .map(
                  (x) => SubtitleFile.fromJson(
                    Map<String, dynamic>.from(x as Map),
                  ),
                )
                .toList()
          : null,
      drmKid: json['drmKid'] as String?,
      drmKey: json['drmKey'] as String?,
      licenseUrl: json['licenseUrl'] as String?,
    );
  }
}

class SubtitleFile {
  final String url;
  final String label;
  final String? lang;

  SubtitleFile({required this.url, required this.label, this.lang});

  Map<String, dynamic> toJson() => {'url': url, 'label': label, 'lang': lang};

  factory SubtitleFile.fromJson(Map<String, dynamic> json) {
    return SubtitleFile(
      url: (json['url'] as String?) ?? '',
      label: (json['label'] as String?) ?? 'Unknown',
      lang: json['lang'] as String?,
    );
  }
}
