/// Unified stream/subtitle models for results returned by Stremio add-ons.
library;

import '../../utils/file_size_formatter.dart';

class AddonSubtitle {
  final String id;
  final String url;
  final String lang;

  const AddonSubtitle({required this.id, required this.url, required this.lang});

  factory AddonSubtitle.fromJson(Map<String, dynamic> json) {
    return AddonSubtitle(
      id: (json['id'] as String?) ?? '',
      url: (json['url'] as String?) ?? '',
      lang: (json['lang'] as String?) ?? 'unknown',
    );
  }

  Map<String, dynamic> toJson() => {'id': id, 'url': url, 'lang': lang};
}

/// One playable result from an add-on's `/stream` resource.
///
/// The protocol allows four mutually exclusive "how to play this" fields —
/// `url`, `infoHash` (+`fileIdx`), `ytId` and `externalUrl` — so the model
/// keeps all of them and exposes [kind] for the UI/resolver to branch on.
class AddonStream {
  final String addonId;
  final String addonName;

  final String? url;
  final String? infoHash;
  final int? fileIdx;
  final String? ytId;
  final String? externalUrl;

  final String? name;
  final String? title;
  final String? description;

  /// `sources` from torrent add-ons: `tracker:udp://…` / `dht:<hash>` entries.
  final List<String> sources;

  final Map<String, String>? proxyHeaders;
  final String? bingeGroup;
  final bool notWebReady;
  final int? videoSize;
  final String? filename;
  final List<AddonSubtitle> subtitles;

  const AddonStream({
    required this.addonId,
    required this.addonName,
    this.url,
    this.infoHash,
    this.fileIdx,
    this.ytId,
    this.externalUrl,
    this.name,
    this.title,
    this.description,
    this.sources = const [],
    this.proxyHeaders,
    this.bingeGroup,
    this.notWebReady = false,
    this.videoSize,
    this.filename,
    this.subtitles = const [],
  });

  factory AddonStream.fromJson(
    Map<String, dynamic> json, {
    required String addonId,
    required String addonName,
  }) {
    final hintsRaw = json['behaviorHints'];
    final hints = hintsRaw is Map
        ? Map<String, dynamic>.from(hintsRaw)
        : <String, dynamic>{};

    Map<String, String>? headers;
    final proxy = hints['proxyHeaders'];
    if (proxy is Map) {
      final request = proxy['request'];
      if (request is Map) {
        headers = <String, String>{};
        request.forEach((key, value) {
          if (key is String && value != null) {
            headers![key] = value.toString();
          }
        });
        if (headers.isEmpty) headers = null;
      }
    }

    final subs = <AddonSubtitle>[];
    final rawSubs = json['subtitles'];
    if (rawSubs is List) {
      for (final entry in rawSubs) {
        if (entry is Map) {
          final sub = AddonSubtitle.fromJson(Map<String, dynamic>.from(entry));
          if (sub.url.isNotEmpty) subs.add(sub);
        }
      }
    }

    final rawSources = json['sources'];
    final sources = <String>[];
    if (rawSources is List) {
      for (final entry in rawSources) {
        if (entry is String && entry.isNotEmpty) sources.add(entry);
      }
    }

    return AddonStream(
      addonId: addonId,
      addonName: addonName,
      url: json['url'] as String?,
      infoHash: (json['infoHash'] as String?)?.toLowerCase(),
      fileIdx: (json['fileIdx'] as num?)?.toInt(),
      ytId: json['ytId'] as String?,
      externalUrl: json['externalUrl'] as String?,
      name: json['name'] as String?,
      title: json['title'] as String?,
      description: json['description'] as String?,
      sources: sources,
      proxyHeaders: headers,
      bingeGroup: hints['bingeGroup'] as String?,
      notWebReady: (hints['notWebReady'] as bool?) ?? false,
      videoSize: (hints['videoSize'] as num?)?.toInt(),
      filename: hints['filename'] as String?,
      subtitles: subs,
    );
  }

  AddonStreamKind get kind {
    if (infoHash != null && infoHash!.isNotEmpty) return AddonStreamKind.torrent;
    if (url != null && url!.isNotEmpty) return AddonStreamKind.direct;
    if (ytId != null && ytId!.isNotEmpty) return AddonStreamKind.youtube;
    if (externalUrl != null && externalUrl!.isNotEmpty) {
      return AddonStreamKind.external;
    }
    return AddonStreamKind.unknown;
  }

  bool get isTorrent => kind == AddonStreamKind.torrent;
  bool get isPlayable =>
      kind == AddonStreamKind.direct || kind == AddonStreamKind.torrent;

  /// Direct HTTP links can be handed to the downloader; torrents/YouTube can't.
  bool get isDownloadable =>
      kind == AddonStreamKind.direct &&
      !(url ?? '').startsWith('magnet:') &&
      (url ?? '').startsWith('http');

  /// All free text the add-on gave us, used for quality/size/seed parsing.
  String get searchText => [
    name ?? '',
    title ?? '',
    description ?? '',
    filename ?? '',
    url ?? '',
  ].join(' ');

  String get displayTitle {
    final candidate = (title ?? description ?? '').trim();
    if (candidate.isNotEmpty) return candidate.replaceAll('\n', ' · ');
    final fallback = (filename ?? name ?? '').trim();
    return fallback.isEmpty ? addonName : fallback;
  }

  /// Short label for the add-on/source, e.g. `Torrentio` or `Torrentio · YTS`.
  String get sourceLabel {
    final n = (name ?? '').trim().replaceAll('\n', ' ');
    if (n.isEmpty) return addonName;
    return n;
  }

  static final RegExp _res = RegExp(r'(\d{3,4})\s*[pi]\b', caseSensitive: false);
  static final RegExp _uhd = RegExp(
    r'\b(4k|uhd|2160p?|ultrahd)\b',
    caseSensitive: false,
  );
  static final RegExp _qhd = RegExp(r'\b(2k|1440p?)\b', caseSensitive: false);
  static final RegExp _hdrRe = RegExp(
    r'\b(hdr10\+?|hdr|dolby\s*vision|dovi|\bdv\b)\b',
    caseSensitive: false,
  );
  static final RegExp _camRe = RegExp(
    r'\b(cam|camrip|hdcam|ts|telesync|hdts|screener|scr)\b',
    caseSensitive: false,
  );
  static final RegExp _seedRe = RegExp(r'(?:👤|seeders?[:\s]*)\s*(\d+)');
  static final RegExp _sizeRe = RegExp(
    r'(\d+(?:[.,]\d+)?)\s*(gb|mb|gib|mib)\b',
    caseSensitive: false,
  );

  int get qualityScore {
    final text = searchText;
    if (_uhd.hasMatch(text)) return 2160;
    if (_qhd.hasMatch(text)) return 1440;
    final match = _res.firstMatch(text);
    if (match != null) return int.tryParse(match.group(1)!) ?? 0;
    return 0;
  }

  String get qualityLabel {
    final score = qualityScore;
    if (score >= 2160) return '4K';
    if (score >= 1440) return '2K';
    if (score > 0) return '${score}p';
    if (isCam) return 'CAM';
    return isTorrent ? 'Torrent' : 'Auto';
  }

  bool get isHdr => _hdrRe.hasMatch(searchText);
  bool get isCam => _camRe.hasMatch(searchText);
  bool get isCachedDebrid => RegExp(
    r'\[(rd|pm|ad|dl|oc|tb|ed)\+\]',
    caseSensitive: false,
  ).hasMatch(searchText);

  int? get seeders {
    final match = _seedRe.firstMatch(searchText);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  /// Bytes when the add-on told us (`behaviorHints.videoSize`), otherwise
  /// parsed out of the human-readable description ("💾 2.34 GB").
  int? get sizeBytes {
    if (videoSize != null && videoSize! > 0) return videoSize;
    final match = _sizeRe.firstMatch(searchText);
    if (match == null) return null;
    final value = double.tryParse(match.group(1)!.replaceAll(',', '.'));
    if (value == null) return null;
    final unit = match.group(2)!.toLowerCase();
    final multiplier = unit.startsWith('g') ? 1024 * 1024 * 1024 : 1024 * 1024;
    return (value * multiplier).round();
  }

  String? get sizeLabel {
    final bytes = sizeBytes;
    if (bytes == null || bytes <= 0) return null;
    return formatFileSize(bytes, fractionDigits: 1);
  }

  /// Trackers advertised alongside a torrent result. Passing them into the
  /// magnet link dramatically shortens time-to-first-byte because the client
  /// doesn't have to wait for DHT bootstrap.
  List<String> get trackers => [
    for (final source in sources)
      if (source.startsWith('tracker:')) source.substring('tracker:'.length),
  ];

  String? get magnetUri {
    final hash = infoHash;
    if (hash == null || hash.isEmpty) return null;
    final buffer = StringBuffer('magnet:?xt=urn:btih:$hash');
    final displayName = filename ?? title ?? name;
    if (displayName != null && displayName.trim().isNotEmpty) {
      buffer.write('&dn=${Uri.encodeComponent(displayName.trim())}');
    }
    for (final tracker in trackers) {
      buffer.write('&tr=${Uri.encodeComponent(tracker)}');
    }
    return buffer.toString();
  }

  /// Stable identity used for de-duplication across add-ons.
  String get uniqueKey {
    if (isTorrent) return 'ih:$infoHash:${fileIdx ?? -1}';
    if (url != null) return 'url:$url';
    if (ytId != null) return 'yt:$ytId';
    return 'ext:${externalUrl ?? displayTitle}';
  }
}

enum AddonStreamKind { direct, torrent, youtube, external, unknown }
