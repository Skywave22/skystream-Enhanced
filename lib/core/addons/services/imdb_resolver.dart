import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../network/dio_client_provider.dart';

part 'imdb_resolver.g.dart';

@Riverpod(keepAlive: true)
ImdbResolver imdbResolver(Ref ref) => ImdbResolver(ref.watch(dioClientProvider));

/// Stremio add-ons are addressed by IMDb id (`tt0111161`), but the app's
/// catalogue is TMDB-first. When a title has no IMDb id attached we look it up
/// through Cinemeta's public search catalog — no install required, cached for
/// the session so it costs one request per title at most.
class ImdbResolver {
  ImdbResolver(this._dio);

  final Dio _dio;
  final Map<String, String?> _cache = {};
  final Map<String, Future<String?>> _inFlight = {};

  static const String _cinemeta = 'https://v3-cinemeta.strem.io';
  static const Duration _timeout = Duration(seconds: 10);

  Future<String?> resolve({
    required String title,
    required bool isSeries,
    int? year,
    String? knownImdbId,
  }) async {
    if (knownImdbId != null && knownImdbId.startsWith('tt')) return knownImdbId;
    final key = '${isSeries ? 'series' : 'movie'}|${title.toLowerCase()}|$year';

    if (_cache.containsKey(key)) return _cache[key];
    final pending = _inFlight[key];
    if (pending != null) return pending;

    final future = _search(title: title, isSeries: isSeries, year: year);
    _inFlight[key] = future;
    try {
      final result = await future;
      _cache[key] = result;
      return result;
    } finally {
      _inFlight.remove(key)?.ignore();
    }
  }

  Future<String?> _search({
    required String title,
    required bool isSeries,
    int? year,
  }) async {
    final type = isSeries ? 'series' : 'movie';
    final url =
        '$_cinemeta/catalog/$type/top/search=${Uri.encodeComponent(title)}.json';
    try {
      final response = await _dio.get<dynamic>(
        url,
        options: Options(
          receiveTimeout: _timeout,
          sendTimeout: _timeout,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      final data = response.data;
      if (data is! Map) return null;
      final metas = data['metas'];
      if (metas is! List || metas.isEmpty) return null;

      String normalize(String value) =>
          value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

      final wanted = normalize(title);
      String? fallback;

      for (final entry in metas) {
        if (entry is! Map) continue;
        final map = Map<String, dynamic>.from(entry);
        final id = map['id'] as String?;
        final name = (map['name'] as String?) ?? '';
        if (id == null || !id.startsWith('tt')) continue;
        fallback ??= id;

        final sameTitle = normalize(name) == wanted;
        if (!sameTitle) continue;
        if (year == null) return id;

        final releaseInfo = map['releaseInfo']?.toString() ?? '';
        final match = RegExp(r'(\d{4})').firstMatch(releaseInfo);
        final metaYear = match == null ? null : int.tryParse(match.group(1)!);
        if (metaYear == null || (metaYear - year).abs() <= 1) return id;
      }
      return fallback;
    } catch (error) {
      if (kDebugMode) debugPrint('[ImdbResolver] lookup failed: $error');
      return null;
    }
  }
}
