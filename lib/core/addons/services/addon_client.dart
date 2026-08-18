import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../network/dio_client_provider.dart';
import '../models/addon_meta.dart';
import '../models/addon_stream.dart';
import '../models/stremio_addon.dart';

part 'addon_client.g.dart';

@Riverpod(keepAlive: true)
AddonClient addonClient(Ref ref) => AddonClient(ref.watch(dioClientProvider));

/// Small TTL + single-flight cache.
///
/// Add-on endpoints are pure GETs whose answers barely change within a
/// session, so caching them is the single biggest speed win: re-opening a
/// title, flipping between episodes or bouncing back from the player becomes
/// instant instead of another network round trip. Single-flight coalescing
/// means ten widgets asking for the same catalog issue exactly one request.
class _TtlCache {
  final Map<String, _CacheEntry> _entries = {};
  final Map<String, Future<Object?>> _inFlight = {};
  final int maxEntries;

  _TtlCache({this.maxEntries = 220});

  T? read<T>(String key) {
    final entry = _entries[key];
    if (entry == null) return null;
    if (entry.expiresAt.isBefore(DateTime.now())) {
      _entries.remove(key);
      return null;
    }
    final value = entry.value;
    return value is T ? value : null;
  }

  void write(String key, Object? value, Duration ttl) {
    if (_entries.length >= maxEntries) {
      // Cheap eviction: drop the oldest quarter rather than tracking LRU
      // ordering for what is at most a couple of hundred small maps.
      final keys = _entries.keys.take(maxEntries ~/ 4).toList();
      for (final k in keys) {
        _entries.remove(k);
      }
    }
    _entries[key] = _CacheEntry(value, DateTime.now().add(ttl));
  }

  Future<T> run<T>(String key, Duration ttl, Future<T> Function() task) async {
    final cached = read<T>(key);
    if (cached != null) return cached;

    final pending = _inFlight[key];
    if (pending != null) {
      final value = await pending;
      if (value is T) return value;
    }

    final future = task();
    _inFlight[key] = future;
    try {
      final value = await future;
      write(key, value, ttl);
      return value;
    } finally {
      unawaited(Future<void>.microtask(() => _inFlight.remove(key)));
    }
  }

  void invalidatePrefix(String prefix) {
    _entries.removeWhere((key, _) => key.startsWith(prefix));
  }

  void clear() {
    _entries.clear();
  }
}

class _CacheEntry {
  final Object? value;
  final DateTime expiresAt;
  const _CacheEntry(this.value, this.expiresAt);
}

/// Community add-on entry as published by Stremio's official collection.
class CommunityAddon {
  final String transportUrl;
  final StremioManifest manifest;
  const CommunityAddon({required this.transportUrl, required this.manifest});
}

/// Thin, cached HTTP client speaking the Stremio add-on protocol.
class AddonClient {
  AddonClient(this._dio);

  final Dio _dio;
  final _TtlCache _cache = _TtlCache();

  static const Duration manifestTtl = Duration(hours: 6);
  static const Duration catalogTtl = Duration(minutes: 15);
  static const Duration metaTtl = Duration(minutes: 45);
  static const Duration streamTtl = Duration(minutes: 5);
  static const Duration subtitleTtl = Duration(minutes: 30);

  static const Duration _fastTimeout = Duration(seconds: 12);
  static const Duration _slowTimeout = Duration(seconds: 20);

  Options _options(Duration timeout) => Options(
    responseType: ResponseType.json,
    receiveTimeout: timeout,
    sendTimeout: timeout,
    headers: const {'Accept': 'application/json'},
    // Add-ons behind Cloudflare occasionally answer 403 with a JSON body; let
    // the caller decide instead of throwing on every non-2xx.
    validateStatus: (status) => status != null && status < 500,
  );

  Future<Map<String, dynamic>?> _getJson(
    String url, {
    Duration timeout = _fastTimeout,
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.get<dynamic>(
      url,
      options: _options(timeout),
      cancelToken: cancelToken,
    );
    final data = response.data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return null;
  }

  /// Fetches and parses a manifest. [url] may be any user-pasted shape.
  Future<StremioManifest> fetchManifest(
    String url, {
    bool forceRefresh = false,
  }) async {
    final normalized = AddonUrl.normalize(url);
    final key = 'manifest:$normalized';
    if (forceRefresh) _cache.invalidatePrefix(key);

    return _cache.run(key, manifestTtl, () async {
      final json = await _getJson(normalized, timeout: _slowTimeout);
      if (json == null) {
        throw const AddonException('Add-on did not return a JSON manifest.');
      }
      final manifest = StremioManifest.fromJson(json);
      if (manifest.id.isEmpty && manifest.resources.isEmpty) {
        throw const AddonException(
          'That URL does not look like a Stremio add-on manifest.',
        );
      }
      return manifest;
    });
  }

  String _extraSegment(Map<String, String>? extra) {
    if (extra == null || extra.isEmpty) return '';
    final parts = <String>[];
    extra.forEach((key, value) {
      if (value.isEmpty) return;
      parts.add('$key=${Uri.encodeComponent(value)}');
    });
    if (parts.isEmpty) return '';
    return '/${parts.join('&')}';
  }

  Future<List<AddonMetaPreview>> catalog(
    InstalledAddon addon, {
    required String type,
    required String id,
    Map<String, String>? extra,
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async {
    final url =
        '${addon.baseUrl}/catalog/$type/${Uri.encodeComponent(id)}'
        '${_extraSegment(extra)}.json';
    final key = 'catalog:$url';
    if (forceRefresh) _cache.invalidatePrefix(key);

    return _cache.run(key, catalogTtl, () async {
      final json = await _getJson(url, cancelToken: cancelToken);
      final metas = json?['metas'];
      if (metas is! List) return const <AddonMetaPreview>[];
      final out = <AddonMetaPreview>[];
      for (final entry in metas) {
        if (entry is Map) {
          final preview = AddonMetaPreview.fromJson(
            Map<String, dynamic>.from(entry),
            addonId: addon.id,
            addonName: addon.name,
          );
          if (preview.id.isNotEmpty && preview.name.isNotEmpty) {
            out.add(preview);
          }
        }
      }
      return out;
    });
  }

  Future<AddonMeta?> meta(
    InstalledAddon addon, {
    required String type,
    required String id,
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async {
    final url = '${addon.baseUrl}/meta/$type/${Uri.encodeComponent(id)}.json';
    final key = 'meta:$url';
    if (forceRefresh) _cache.invalidatePrefix(key);

    return _cache.run(key, metaTtl, () async {
      final json = await _getJson(url, cancelToken: cancelToken);
      final meta = json?['meta'];
      if (meta is! Map) return null;
      return AddonMeta.fromJson(
        Map<String, dynamic>.from(meta),
        addonId: addon.id,
        addonName: addon.name,
      );
    });
  }

  Future<List<AddonStream>> streams(
    InstalledAddon addon, {
    required String type,
    required String id,
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async {
    final url = '${addon.baseUrl}/stream/$type/${Uri.encodeComponent(id)}.json';
    final key = 'stream:$url';
    if (forceRefresh) _cache.invalidatePrefix(key);

    return _cache.run(key, streamTtl, () async {
      final json = await _getJson(
        url,
        timeout: _slowTimeout,
        cancelToken: cancelToken,
      );
      final streams = json?['streams'];
      if (streams is! List) return const <AddonStream>[];
      final out = <AddonStream>[];
      for (final entry in streams) {
        if (entry is Map) {
          final stream = AddonStream.fromJson(
            Map<String, dynamic>.from(entry),
            addonId: addon.id,
            addonName: addon.name,
          );
          if (stream.kind != AddonStreamKind.unknown) out.add(stream);
        }
      }
      return out;
    });
  }

  Future<List<AddonSubtitle>> subtitles(
    InstalledAddon addon, {
    required String type,
    required String id,
    Map<String, String>? extra,
    CancelToken? cancelToken,
  }) async {
    final url =
        '${addon.baseUrl}/subtitles/$type/${Uri.encodeComponent(id)}'
        '${_extraSegment(extra)}.json';

    return _cache.run('subs:$url', subtitleTtl, () async {
      final json = await _getJson(url, cancelToken: cancelToken);
      final subs = json?['subtitles'];
      if (subs is! List) return const <AddonSubtitle>[];
      final out = <AddonSubtitle>[];
      for (final entry in subs) {
        if (entry is Map) {
          final sub = AddonSubtitle.fromJson(Map<String, dynamic>.from(entry));
          if (sub.url.isNotEmpty) out.add(sub);
        }
      }
      return out;
    });
  }

  /// Stremio's official community collection, used to power the in-app
  /// "Discover add-ons" list so users don't have to hunt for manifest URLs.
  Future<List<CommunityAddon>> communityAddons({
    bool forceRefresh = false,
  }) async {
    const key = 'community:list';
    if (forceRefresh) _cache.invalidatePrefix(key);

    return _cache.run(key, const Duration(hours: 3), () async {
      try {
        final response = await _dio.get<dynamic>(
          'https://api.strem.io/addonscollection.json',
          options: _options(_slowTimeout),
        );
        final data = response.data;
        if (data is! List) return const <CommunityAddon>[];
        final out = <CommunityAddon>[];
        for (final entry in data) {
          if (entry is! Map) continue;
          final map = Map<String, dynamic>.from(entry);
          final transportUrl = map['transportUrl'] as String?;
          final manifest = map['manifest'];
          if (transportUrl == null || manifest is! Map) continue;
          out.add(
            CommunityAddon(
              transportUrl: transportUrl,
              manifest: StremioManifest.fromJson(
                Map<String, dynamic>.from(manifest),
              ),
            ),
          );
        }
        return out;
      } catch (error) {
        if (kDebugMode) debugPrint('[AddonClient] community list failed: $error');
        return const <CommunityAddon>[];
      }
    });
  }

  void invalidateAddon(InstalledAddon addon) {
    _cache.invalidatePrefix('catalog:${addon.baseUrl}');
    _cache.invalidatePrefix('meta:${addon.baseUrl}');
    _cache.invalidatePrefix('stream:${addon.baseUrl}');
    _cache.invalidatePrefix('subs:${addon.baseUrl}');
  }

  void clearCache() => _cache.clear();
}

class AddonException implements Exception {
  final String message;
  const AddonException(this.message);
  @override
  String toString() => message;
}
