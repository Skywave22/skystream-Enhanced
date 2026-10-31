/// CloudStream extension repositories and plugins, in CloudStream's own JSON formats.
///
/// A repository manifest (`repo.json`) names plugin lists; a plugin list (`plugins.json`) is an
/// array of plugins, each a `.cs3` file (DEX code) that the CS3 engine loads.
library;

/// The text [value] holds, or null when it holds none: a repository that writes a field as
/// something else does not make the whole entry unreadable.
String? _text(Object? value) => value is String && value.isNotEmpty ? value : null;

/// The whole number [value] holds: a repository that writes it as text ("2") is read as well.
int? _number(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

/// The name of the file [url] points at, without its extension: what a plugin that names itself
/// after its file is called.
String _fileName(String url) {
  final path = Uri.tryParse(url)?.path ?? '';
  final last = path.split('/').where((part) => part.isNotEmpty).toList();
  if (last.isEmpty) return '';
  final name = last.last;
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// A repository the user added.
class CsRepository {
  const CsRepository({
    required this.url,
    required this.name,
    this.description,
    this.iconUrl,
    this.plugins = const [],
    this.error,
  });

  /// Where it was added from; also the repository's identity.
  final String url;
  final String name;
  final String? description;
  final String? iconUrl;

  /// The plugins its lists offered when last fetched.
  final List<CsPluginInfo> plugins;

  /// Why the last check failed, if it did; [plugins] are then from the one before.
  final String? error;

  CsRepository withError(String error) =>
      CsRepository(url: url, name: name, description: description, iconUrl: iconUrl, plugins: plugins, error: error);

  Map<String, dynamic> toJson() => {
    'url': url,
    'name': name,
    'description': description,
    'iconUrl': iconUrl,
    'plugins': [for (final p in plugins) p.toJson()],
  };

  factory CsRepository.fromJson(Map<String, dynamic> json) {
    final url = json['url'];
    if (url is! String || url.isEmpty) throw const FormatException('A repository needs its address');
    final host = Uri.tryParse(url)?.host ?? '';
    return CsRepository(
      url: url,
      name: _text(json['name']) ?? (host.isEmpty ? url : host),
      description: _text(json['description']),
      iconUrl: _text(json['iconUrl']),
      plugins: _plugins(json['plugins'], url),
    );
  }

  /// The plugins [raw] holds: one that does not read is left out, not the repository with it -
  /// a repository is lost whole when one of its entries throws.
  static List<CsPluginInfo> _plugins(Object? raw, String repositoryUrl) {
    final out = <CsPluginInfo>[];
    if (raw is! List) return out;
    for (final entry in raw) {
      if (entry is! Map) continue;
      try {
        out.add(CsPluginInfo.fromJson(Map<String, dynamic>.from(entry), repositoryUrl));
      } on FormatException {
        // A plugin entry that does not read is left out, not the repository with it.
      }
    }
    return out;
  }
}

/// One entry of a plugin list.
class CsPluginInfo {
  const CsPluginInfo({
    required this.internalName,
    required this.name,
    required this.url,
    required this.repositoryUrl,
    this.version = 0,
    this.status = 1,
    this.authors = const [],
    this.description,
    this.tvTypes = const [],
    this.language,
    this.iconUrl,
    this.fileSize,
  });

  /// Unique within a repository; names the file and the providers' ids.
  final String internalName;
  final String name;

  /// The `.cs3` download.
  final String url;

  /// The [CsRepository.url] that lists it.
  final String repositoryUrl;
  final int version;

  /// CloudStream's status: 0 down, 1 ok, 2 slow, 3 beta.
  final int status;
  final List<String> authors;
  final String? description;
  final List<String> tvTypes;
  final String? language;
  final String? iconUrl;

  /// The download's size in bytes, when the list gives it.
  final int? fileSize;

  bool get isDown => status == 0;

  Map<String, dynamic> toJson() => {
    'internalName': internalName,
    'name': name,
    'url': url,
    'version': version,
    'status': status,
    'authors': authors,
    'description': description,
    'tvTypes': tvTypes,
    'language': language,
    'iconUrl': iconUrl,
    'fileSize': fileSize,
  };

  factory CsPluginInfo.fromJson(Map<String, dynamic> json, String repositoryUrl) {
    final url = json['url'];
    if (url is! String || url.isEmpty) throw const FormatException('A plugin needs its address');
    // A plugin names itself; a list that names it only one way still reads.
    final name = _text(json['name']);
    final internalName = _text(json['internalName']) ?? name ?? _fileName(url);
    return CsPluginInfo(
      internalName: internalName,
      name: name ?? internalName,
      url: url,
      repositoryUrl: repositoryUrl,
      version: _number(json['version']) ?? 0,
      status: _number(json['status']) ?? 1,
      authors: [...?(json['authors'] as List?)?.whereType<String>()],
      description: _text(json['description']),
      tvTypes: [...?(json['tvTypes'] as List?)?.whereType<String>()],
      language: _text(json['language']),
      iconUrl: _text(json['iconUrl'])?.replaceAll('%size%', '128'),
      fileSize: _number(json['fileSize']),
    );
  }
}

/// A provider (CloudStream's `MainAPI`) that a plugin registers when loaded.
class CsProviderInfo {
  const CsProviderInfo({
    required this.name,
    this.mainUrl = '',
    this.lang,
    this.types = const [],
    this.hasMainPage = false,
    this.sections = const [],
  });

  final String name;
  final String mainUrl;
  final String? lang;

  /// CloudStream `TvType` names, e.g. `Movie`, `TvSeries`, `Anime`, `Live`.
  final List<String> types;
  final bool hasMainPage;

  /// Home page section names, in the provider's order.
  final List<String> sections;

  Map<String, dynamic> toJson() => {
    'name': name,
    'mainUrl': mainUrl,
    'lang': lang,
    'types': types,
    'hasMainPage': hasMainPage,
    'sections': sections,
  };

  factory CsProviderInfo.fromJson(Map<String, dynamic> json) => CsProviderInfo(
    name: _text(json['name']) ?? 'CloudStream',
    mainUrl: _text(json['mainUrl']) ?? '',
    lang: _text(json['lang']),
    types: [...?(json['types'] as List?)?.whereType<String>()],
    hasMainPage: json['hasMainPage'] == true,
    sections: [...?(json['sections'] as List?)?.whereType<String>()],
  );
}

/// A plugin installed on this device, with what it registered when last loaded.
///
/// That is recorded so its providers can be listed at launch without starting the engine.
class CsInstalledPlugin {
  const CsInstalledPlugin({
    required this.info,
    required this.filePath,
    this.providers = const [],
    this.extractors = 0,
    this.loadError,
    this.loadErrorVersion,
    this.hasSettings,
  });

  final CsPluginInfo info;
  final String filePath;
  final List<CsProviderInfo> providers;

  /// Link extractors it registered, which other plugins' links can come through.
  final int extractors;

  /// Why the engine could not load it at install time, if it could not.
  final String? loadError;

  /// The app version whose engine could not load it. The engine comes with the app, so the launch
  /// pass tries it again under another version.
  final String? loadErrorVersion;

  /// Whether it has its own settings screen (CloudStream's `openSettings`); null until a load says.
  final bool? hasSettings;

  CsInstalledPlugin withSettings(bool? value) => CsInstalledPlugin(
    info: info,
    filePath: filePath,
    providers: providers,
    extractors: extractors,
    loadError: loadError,
    loadErrorVersion: loadErrorVersion,
    hasSettings: value,
  );

  /// Its file, relative to [root] (CloudStream's folder): an app's container path can change
  /// between versions (iOS), so absolute paths are not stored.
  Map<String, dynamic> toJson(String root) => {
    'info': info.toJson(),
    'repositoryUrl': info.repositoryUrl,
    'file': _relative(filePath, root),
    'providers': [for (final p in providers) p.toJson()],
    'extractors': extractors,
    'loadError': loadError,
    'loadErrorVersion': loadErrorVersion,
    'hasSettings': hasSettings,
  };

  factory CsInstalledPlugin.fromJson(Map<String, dynamic> json, String root) => CsInstalledPlugin(
    info: CsPluginInfo.fromJson(
      Map<String, dynamic>.from(json['info'] as Map),
      _text(json['repositoryUrl']) ?? '',
    ),
    filePath: _resolve(json, root),
    providers: [
      for (final p in (json['providers'] as List?) ?? const [])
        if (p is Map) CsProviderInfo.fromJson(Map<String, dynamic>.from(p)),
    ],
    extractors: _number(json['extractors']) ?? 0,
    loadError: _text(json['loadError']),
    loadErrorVersion: _text(json['loadErrorVersion']),
    hasSettings: json['hasSettings'] as bool?,
  );

  static String _relative(String path, String root) {
    final normalized = path.replaceAll('\\', '/');
    final base = '${root.replaceAll('\\', '/')}/';
    return normalized.startsWith(base) ? normalized.substring(base.length) : normalized;
  }

  static String _resolve(Map<String, dynamic> json, String root) {
    final file = _text(json['file']);
    if (file != null) return file.startsWith('/') || file.contains(':') ? file : '$root/$file';
    // Recorded as an absolute path before: keep the part inside CloudStream's folder.
    final legacy = (_text(json['filePath']) ?? '').replaceAll('\\', '/');
    const marker = '/extensions/cloudstream/';
    final at = legacy.indexOf(marker);
    return at < 0 ? legacy : '$root/${legacy.substring(at + marker.length)}';
  }
}
