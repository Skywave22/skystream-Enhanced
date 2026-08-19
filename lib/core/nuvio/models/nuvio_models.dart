/// Models for Nuvio-style scraper plugins.
///
/// Nuvio (github.com/NuvioMedia/NuvioMobile) ships "plugins" that are JS
/// scrapers listed in a manifest:
///
/// ```json
/// { "name": "My plugins", "version": "1.0.0",
///   "scrapers": [ { "id": "x", "name": "X", "version": "1.0.0",
///                   "filename": "x.js", "supportedTypes": ["movie","tv"] } ] }
/// ```
///
/// Each scraper file exports `getStreams(tmdbId, mediaType, season, episode)`
/// and returns a list of link objects. SkyStream runs them alongside its own
/// plugins so both systems contribute links to the same sheet.
library;

import '../../domain/entity/multimedia_item.dart';

class NuvioScraperInfo {
  final String id;
  final String name;
  final String description;
  final String version;
  final String filename;
  final List<String> supportedTypes;
  final bool manifestEnabled;
  final String? logo;
  final List<String> contentLanguage;

  const NuvioScraperInfo({
    required this.id,
    required this.name,
    required this.version,
    required this.filename,
    this.description = '',
    this.supportedTypes = const ['movie', 'tv'],
    this.manifestEnabled = true,
    this.logo,
    this.contentLanguage = const [],
  });

  factory NuvioScraperInfo.fromJson(Map<String, dynamic> json) {
    return NuvioScraperInfo(
      id: (json['id'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      version: (json['version'] as String?) ?? '0.0.0',
      filename: (json['filename'] as String?) ?? '',
      description: (json['description'] as String?) ?? '',
      supportedTypes: _stringList(json['supportedTypes']).isEmpty
          ? const ['movie', 'tv']
          : _stringList(json['supportedTypes']),
      manifestEnabled: (json['enabled'] as bool?) ?? true,
      logo: json['logo'] as String?,
      contentLanguage: _stringList(json['contentLanguage']),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'filename': filename,
    'description': description,
    'supportedTypes': supportedTypes,
    'enabled': manifestEnabled,
    'logo': logo,
    'contentLanguage': contentLanguage,
  };

  /// Nuvio uses `movie` / `tv`; SkyStream and Stremio say `movie` / `series`.
  static String normalizeType(String type) {
    final t = type.toLowerCase();
    if (t == 'series' || t == 'show' || t == 'anime') return 'tv';
    if (t == 'film') return 'movie';
    return t;
  }

  bool supportsType(String type) {
    final wanted = normalizeType(type);
    return supportedTypes.map(normalizeType).contains(wanted);
  }
}

class NuvioManifest {
  final String name;
  final String version;
  final String description;
  final String? author;
  final List<NuvioScraperInfo> scrapers;

  const NuvioManifest({
    required this.name,
    required this.version,
    this.description = '',
    this.author,
    this.scrapers = const [],
  });

  factory NuvioManifest.fromJson(Map<String, dynamic> json) {
    final scrapers = <NuvioScraperInfo>[];
    final raw = json['scrapers'];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is Map) {
          final scraper = NuvioScraperInfo.fromJson(
            Map<String, dynamic>.from(entry),
          );
          if (scraper.id.isNotEmpty && scraper.filename.isNotEmpty) {
            scrapers.add(scraper);
          }
        }
      }
    }
    return NuvioManifest(
      name: (json['name'] as String?) ?? '',
      version: (json['version'] as String?) ?? '',
      description: (json['description'] as String?) ?? '',
      author: json['author'] as String?,
      scrapers: scrapers,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'version': version,
    'description': description,
    'author': author,
    'scrapers': scrapers.map((s) => s.toJson()).toList(),
  };

  bool get isValid =>
      name.trim().isNotEmpty && version.trim().isNotEmpty && scrapers.isNotEmpty;
}

/// A repository the user added, plus the scrapers it published.
class NuvioRepo {
  final String manifestUrl;
  final NuvioManifest? manifest;
  final DateTime addedAt;
  final String? errorMessage;

  /// Scraper ids the user switched off locally.
  final Set<String> disabledScrapers;

  const NuvioRepo({
    required this.manifestUrl,
    required this.addedAt,
    this.manifest,
    this.errorMessage,
    this.disabledScrapers = const {},
  });

  String get displayName =>
      manifest?.name ?? Uri.tryParse(manifestUrl)?.host ?? manifestUrl;

  bool isScraperEnabled(NuvioScraperInfo scraper) =>
      scraper.manifestEnabled && !disabledScrapers.contains(scraper.id);

  List<NuvioScraperInfo> get enabledScrapers => [
    for (final scraper in manifest?.scrapers ?? const <NuvioScraperInfo>[])
      if (isScraperEnabled(scraper)) scraper,
  ];

  /// Scraper code lives next to the manifest.
  Uri? codeUrlFor(NuvioScraperInfo scraper) =>
      NuvioUrls.resolveCodeUrl(manifestUrl, scraper.filename);

  NuvioRepo copyWith({
    NuvioManifest? manifest,
    String? errorMessage,
    bool clearError = false,
    Set<String>? disabledScrapers,
  }) {
    return NuvioRepo(
      manifestUrl: manifestUrl,
      addedAt: addedAt,
      manifest: manifest ?? this.manifest,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      disabledScrapers: disabledScrapers ?? this.disabledScrapers,
    );
  }

  Map<String, dynamic> toJson() => {
    'manifestUrl': manifestUrl,
    'addedAt': addedAt.toIso8601String(),
    'manifest': manifest?.toJson(),
    'disabled': disabledScrapers.toList(),
  };

  static NuvioRepo? fromJson(Map<String, dynamic> json) {
    final url = json['manifestUrl'] as String?;
    if (url == null || url.isEmpty) return null;
    final rawManifest = json['manifest'];
    return NuvioRepo(
      manifestUrl: url,
      addedAt:
          DateTime.tryParse((json['addedAt'] as String?) ?? '') ??
          DateTime.now(),
      manifest: rawManifest is Map
          ? NuvioManifest.fromJson(Map<String, dynamic>.from(rawManifest))
          : null,
      disabledScrapers: {
        for (final id in _stringList(json['disabled'])) id,
      },
    );
  }
}

/// One link produced by a Nuvio scraper.
class NuvioStreamResult {
  final String scraperId;
  final String scraperName;
  final String title;
  final String? name;
  final String url;
  final String? quality;
  final String? size;
  final String? language;
  final String? provider;
  final String? type;
  final int? seeders;
  final String? infoHash;
  final Map<String, String>? headers;
  final List<SubtitleFile> subtitles;

  const NuvioStreamResult({
    required this.scraperId,
    required this.scraperName,
    required this.title,
    required this.url,
    this.name,
    this.quality,
    this.size,
    this.language,
    this.provider,
    this.type,
    this.seeders,
    this.infoHash,
    this.headers,
    this.subtitles = const [],
  });

  /// Nuvio scrapers are loose about shapes: `url` can be a string or an
  /// object, headers/subtitles may be missing, numbers arrive as strings.
  static NuvioStreamResult? fromJson(
    Map<String, dynamic> json, {
    required String scraperId,
    required String scraperName,
  }) {
    String? url;
    final rawUrl = json['url'];
    if (rawUrl is String) {
      url = rawUrl.trim();
    } else if (rawUrl is Map && rawUrl['url'] is String) {
      url = (rawUrl['url'] as String).trim();
    }
    final infoHash = (json['infoHash'] as String?)?.trim();
    if ((url == null || url.isEmpty) && (infoHash == null || infoHash.isEmpty)) {
      return null;
    }

    Map<String, String>? headers;
    final rawHeaders = json['headers'];
    if (rawHeaders is Map) {
      final map = <String, String>{};
      rawHeaders.forEach((key, value) {
        if (key is String && value != null) map[key] = value.toString();
      });
      if (map.isNotEmpty) headers = map;
    }

    final subtitles = <SubtitleFile>[];
    final rawSubs = json['subtitles'];
    if (rawSubs is List) {
      for (final entry in rawSubs) {
        if (entry is! Map) continue;
        final subUrl = entry['url'];
        if (subUrl is! String || subUrl.isEmpty) continue;
        final lang = (entry['language'] ?? entry['lang'] ?? 'und').toString();
        subtitles.add(
          SubtitleFile(
            url: subUrl,
            label: (entry['name'] as String?) ?? lang,
            lang: lang,
          ),
        );
      }
    }

    return NuvioStreamResult(
      scraperId: scraperId,
      scraperName: scraperName,
      title: (json['title'] ?? json['name'] ?? scraperName).toString(),
      name: json['name']?.toString(),
      url: url ?? 'magnet:?xt=urn:btih:$infoHash',
      quality: json['quality']?.toString(),
      size: json['size']?.toString(),
      language: json['language']?.toString(),
      provider: json['provider']?.toString(),
      type: json['type']?.toString(),
      seeders: _asInt(json['seeders']),
      infoHash: infoHash,
      headers: headers,
      subtitles: subtitles,
    );
  }

  bool get isTorrent =>
      url.startsWith('magnet:') || (infoHash?.isNotEmpty ?? false);

  /// Label shown in the sources list / player.
  String get label {
    final parts = <String>[
      if (quality != null && quality!.trim().isNotEmpty) quality!.trim(),
      if (size != null && size!.trim().isNotEmpty) size!.trim(),
      if (language != null && language!.trim().isNotEmpty) language!.trim(),
      if (seeders != null) '${seeders!} seeds',
    ];
    if (parts.isEmpty) return title;
    return parts.join(' · ');
  }

  StreamResult toStreamResult() => StreamResult(
    url: url,
    source: label,
    providerName: provider?.trim().isNotEmpty ?? false
        ? '$scraperName · ${provider!.trim()}'
        : scraperName,
    headers: headers,
    subtitles: subtitles.isEmpty ? null : subtitles,
  );
}

class NuvioUrls {
  const NuvioUrls._();

  /// Accepts bare hosts and direct manifest links, like the add-on installer.
  static String normalizeManifestUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return url;
    if (url.startsWith('nuvio://')) {
      url = 'https://${url.substring('nuvio://'.length)}';
    } else if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    url = url.split('#').first;
    if (!url.split('?').first.toLowerCase().endsWith('.json')) {
      final base = url.split('?').first;
      final query = url.contains('?') ? url.substring(url.indexOf('?')) : '';
      final trimmed = base.endsWith('/')
          ? base.substring(0, base.length - 1)
          : base;
      url = '$trimmed/manifest.json$query';
    }
    return url;
  }

  /// `filename` may be a bare name, a relative path or an absolute URL.
  static Uri? resolveCodeUrl(String manifestUrl, String filename) {
    if (filename.trim().isEmpty) return null;
    final manifest = Uri.tryParse(manifestUrl);
    if (manifest == null) return null;
    return manifest.resolve(filename);
  }
}

int? _asInt(dynamic value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

List<String> _stringList(dynamic raw) {
  if (raw is! List) return const [];
  final out = <String>[];
  for (final entry in raw) {
    if (entry is String && entry.trim().isNotEmpty) out.add(entry.trim());
  }
  return out;
}
