/// Data model layer for the Stremio add-on protocol.
///
/// A Stremio add-on is a plain HTTP server that exposes a `manifest.json`
/// describing which *resources* (`catalog`, `meta`, `stream`, `subtitles`) it
/// can answer for which content *types* (`movie`, `series`, `anime`, `tv`...).
/// Everything else in the protocol is derived from those declarations, so the
/// manifest is the single source of truth this app keeps in storage.
library;

/// One `extra` parameter a catalog accepts (`search`, `genre`, `skip`).
class AddonCatalogExtra {
  final String name;
  final bool isRequired;
  final List<String> options;
  final int? optionsLimit;

  const AddonCatalogExtra({
    required this.name,
    this.isRequired = false,
    this.options = const [],
    this.optionsLimit,
  });

  factory AddonCatalogExtra.fromJson(Map<String, dynamic> json) {
    return AddonCatalogExtra(
      name: (json['name'] as String?) ?? '',
      isRequired: (json['isRequired'] as bool?) ?? false,
      options: _stringList(json['options']),
      optionsLimit: (json['optionsLimit'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'isRequired': isRequired,
    'options': options,
    if (optionsLimit != null) 'optionsLimit': optionsLimit,
  };
}

/// A single catalog row an add-on publishes (`/catalog/{type}/{id}.json`).
class AddonCatalogDefinition {
  final String type;
  final String id;
  final String name;
  final List<AddonCatalogExtra> extra;

  const AddonCatalogDefinition({
    required this.type,
    required this.id,
    required this.name,
    this.extra = const [],
  });

  factory AddonCatalogDefinition.fromJson(Map<String, dynamic> json) {
    final extras = <AddonCatalogExtra>[];

    final rawExtra = json['extra'];
    if (rawExtra is List) {
      for (final entry in rawExtra) {
        if (entry is Map) {
          extras.add(
            AddonCatalogExtra.fromJson(Map<String, dynamic>.from(entry)),
          );
        }
      }
    }

    // Legacy manifests use extraSupported / extraRequired string lists.
    final supported = _stringList(json['extraSupported']);
    final required = _stringList(json['extraRequired']);
    for (final name in supported) {
      if (extras.any((e) => e.name == name)) continue;
      extras.add(
        AddonCatalogExtra(name: name, isRequired: required.contains(name)),
      );
    }
    for (final name in required) {
      if (extras.any((e) => e.name == name)) continue;
      extras.add(AddonCatalogExtra(name: name, isRequired: true));
    }

    final id = (json['id'] as String?) ?? '';
    final type = (json['type'] as String?) ?? '';
    return AddonCatalogDefinition(
      type: type,
      id: id,
      name: (json['name'] as String?) ?? (id.isEmpty ? type : id),
      extra: extras,
    );
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    'id': id,
    'name': name,
    'extra': extra.map((e) => e.toJson()).toList(),
  };

  bool get supportsSearch => extra.any((e) => e.name == 'search');

  /// Catalogs that only answer when `search=` is supplied must not be shown as
  /// browsable rows — Cinemeta's `top` search catalog is the classic case.
  bool get requiresSearch =>
      extra.any((e) => e.name == 'search' && e.isRequired);

  bool get requiresOtherExtra =>
      extra.any((e) => e.isRequired && e.name != 'search' && e.name != 'skip');

  bool get supportsSkip => extra.any((e) => e.name == 'skip');

  List<String> get genres =>
      extra.firstWhere(
        (e) => e.name == 'genre',
        orElse: () => const AddonCatalogExtra(name: 'genre'),
      ).options;

  String get uniqueKey => '$type/$id';
}

/// A declared resource. Manifests allow either a bare string (`"stream"`) or
/// an object with per-resource type/idPrefix narrowing.
class AddonResourceDefinition {
  final String name;
  final List<String> types;
  final List<String> idPrefixes;

  const AddonResourceDefinition({
    required this.name,
    this.types = const [],
    this.idPrefixes = const [],
  });

  factory AddonResourceDefinition.fromDynamic(dynamic raw) {
    if (raw is String) return AddonResourceDefinition(name: raw);
    if (raw is Map) {
      final map = Map<String, dynamic>.from(raw);
      return AddonResourceDefinition(
        name: (map['name'] as String?) ?? '',
        types: _stringList(map['types']),
        idPrefixes: _stringList(map['idPrefixes']),
      );
    }
    return const AddonResourceDefinition(name: '');
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'types': types,
    'idPrefixes': idPrefixes,
  };
}

/// Parsed `manifest.json` of a Stremio add-on.
class StremioManifest {
  final String id;
  final String name;
  final String version;
  final String description;
  final String? logo;
  final String? background;
  final List<String> types;
  final List<AddonResourceDefinition> resources;
  final List<AddonCatalogDefinition> catalogs;
  final List<String> idPrefixes;
  final bool configurable;
  final bool configurationRequired;
  final bool adult;
  final bool p2p;

  const StremioManifest({
    required this.id,
    required this.name,
    required this.version,
    this.description = '',
    this.logo,
    this.background,
    this.types = const [],
    this.resources = const [],
    this.catalogs = const [],
    this.idPrefixes = const [],
    this.configurable = false,
    this.configurationRequired = false,
    this.adult = false,
    this.p2p = false,
  });

  factory StremioManifest.fromJson(Map<String, dynamic> json) {
    final resources = <AddonResourceDefinition>[];
    final rawResources = json['resources'];
    if (rawResources is List) {
      for (final entry in rawResources) {
        final parsed = AddonResourceDefinition.fromDynamic(entry);
        if (parsed.name.isNotEmpty) resources.add(parsed);
      }
    }

    final catalogs = <AddonCatalogDefinition>[];
    final rawCatalogs = json['catalogs'];
    if (rawCatalogs is List) {
      for (final entry in rawCatalogs) {
        if (entry is Map) {
          catalogs.add(
            AddonCatalogDefinition.fromJson(Map<String, dynamic>.from(entry)),
          );
        }
      }
    }

    final hints = json['behaviorHints'];
    final hintMap = hints is Map
        ? Map<String, dynamic>.from(hints)
        : <String, dynamic>{};

    return StremioManifest(
      id: (json['id'] as String?) ?? '',
      name: (json['name'] as String?) ?? 'Unnamed add-on',
      version: (json['version'] as String?) ?? '0.0.0',
      description: (json['description'] as String?) ?? '',
      logo: json['logo'] as String?,
      background: json['background'] as String?,
      types: _stringList(json['types']),
      resources: resources,
      catalogs: catalogs,
      idPrefixes: _stringList(json['idPrefixes']),
      configurable: (hintMap['configurable'] as bool?) ?? false,
      configurationRequired:
          (hintMap['configurationRequired'] as bool?) ?? false,
      adult: (hintMap['adult'] as bool?) ?? false,
      p2p: (hintMap['p2p'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'description': description,
    'logo': logo,
    'background': background,
    'types': types,
    'resources': resources.map((r) => r.toJson()).toList(),
    'catalogs': catalogs.map((c) => c.toJson()).toList(),
    'idPrefixes': idPrefixes,
    'behaviorHints': {
      'configurable': configurable,
      'configurationRequired': configurationRequired,
      'adult': adult,
      'p2p': p2p,
    },
  };

  bool hasResource(String resource) =>
      resources.any((r) => r.name == resource);

  /// True when this add-on claims it can answer `resource` for `type`/`id`.
  /// Cheap client-side filtering like this is what keeps the fan-out fast:
  /// an add-on that can't possibly answer is never contacted.
  bool supports(String resource, String type, [String? id]) {
    AddonResourceDefinition? match;
    for (final r in resources) {
      if (r.name == resource) {
        match = r;
        break;
      }
    }
    if (match == null) return false;

    final allowedTypes = match.types.isNotEmpty ? match.types : types;
    if (allowedTypes.isNotEmpty && !allowedTypes.contains(type)) return false;

    if (id != null && id.isNotEmpty) {
      final prefixes = match.idPrefixes.isNotEmpty
          ? match.idPrefixes
          : idPrefixes;
      if (prefixes.isNotEmpty && !prefixes.any(id.startsWith)) return false;
    }
    return true;
  }
}

/// A manifest plus the local state SkyStream keeps about it.
class InstalledAddon {
  final String transportUrl;
  final StremioManifest manifest;
  final bool enabled;
  final DateTime installedAt;

  const InstalledAddon({
    required this.transportUrl,
    required this.manifest,
    this.enabled = true,
    required this.installedAt,
  });

  String get id => manifest.id.isNotEmpty ? manifest.id : transportUrl;
  String get name => manifest.name;

  /// `https://host/config/manifest.json` -> `https://host/config`
  String get baseUrl => AddonUrl.baseOf(transportUrl);

  InstalledAddon copyWith({
    String? transportUrl,
    StremioManifest? manifest,
    bool? enabled,
    DateTime? installedAt,
  }) {
    return InstalledAddon(
      transportUrl: transportUrl ?? this.transportUrl,
      manifest: manifest ?? this.manifest,
      enabled: enabled ?? this.enabled,
      installedAt: installedAt ?? this.installedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'transportUrl': transportUrl,
    'manifest': manifest.toJson(),
    'enabled': enabled,
    'installedAt': installedAt.toIso8601String(),
  };

  static InstalledAddon? fromJson(Map<String, dynamic> json) {
    final url = json['transportUrl'] as String?;
    final rawManifest = json['manifest'];
    if (url == null || url.isEmpty || rawManifest is! Map) return null;
    return InstalledAddon(
      transportUrl: url,
      manifest: StremioManifest.fromJson(
        Map<String, dynamic>.from(rawManifest),
      ),
      enabled: (json['enabled'] as bool?) ?? true,
      installedAt:
          DateTime.tryParse((json['installedAt'] as String?) ?? '') ??
          DateTime.now(),
    );
  }
}

/// URL shapes users paste vary a lot (`stremio://`, bare host, deep config
/// paths). Everything is funnelled through here so the rest of the code only
/// ever deals with a canonical `https://…/manifest.json`.
class AddonUrl {
  const AddonUrl._();

  static String normalize(String input) {
    var url = input.trim();
    if (url.isEmpty) return url;

    if (url.startsWith('stremio://')) {
      url = url.replaceFirst('stremio://', 'https://');
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    // Strip query/hash noise from copied browser URLs.
    final hashIndex = url.indexOf('#');
    if (hashIndex > 0) url = url.substring(0, hashIndex);

    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    if (!url.endsWith('manifest.json')) {
      url = '$url/manifest.json';
    }
    return url;
  }

  static String baseOf(String transportUrl) {
    const suffix = '/manifest.json';
    if (transportUrl.endsWith(suffix)) {
      return transportUrl.substring(0, transportUrl.length - suffix.length);
    }
    return transportUrl;
  }

  static bool looksValid(String input) {
    final normalized = normalize(input);
    final uri = Uri.tryParse(normalized);
    return uri != null && uri.hasAuthority;
  }
}

List<String> _stringList(dynamic raw) {
  if (raw is! List) return const [];
  final out = <String>[];
  for (final entry in raw) {
    if (entry is String && entry.isNotEmpty) out.add(entry);
  }
  return out;
}
