import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../network/dio_client_provider.dart';
import '../models/nuvio_models.dart';

part 'nuvio_repository.g.dart';

class NuvioState {
  final List<NuvioRepo> repos;
  final bool enabled;
  final bool isLoading;

  const NuvioState({
    this.repos = const [],
    this.enabled = true,
    this.isLoading = true,
  });

  List<({NuvioRepo repo, NuvioScraperInfo scraper})> get activeScrapers => [
    if (enabled)
      for (final repo in repos)
        for (final scraper in repo.enabledScrapers)
          (repo: repo, scraper: scraper),
  ];

  NuvioState copyWith({
    List<NuvioRepo>? repos,
    bool? enabled,
    bool? isLoading,
  }) => NuvioState(
    repos: repos ?? this.repos,
    enabled: enabled ?? this.enabled,
    isLoading: isLoading ?? this.isLoading,
  );
}

/// Stores Nuvio plugin repositories and the scraper code they publish.
///
/// This sits next to — not inside — the SkyStream plugin system: both are
/// "plugins", both feed the same sources sheet, but they speak different
/// protocols and are managed separately.
@Riverpod(keepAlive: true)
class NuvioRepository extends _$NuvioRepository {
  static const String _reposKey = 'nuvio_repos_v1';
  static const String _enabledKey = 'nuvio_enabled_v1';
  static const String _codePrefix = 'nuvio_code_';

  final Map<String, String> _codeCache = {};

  @override
  NuvioState build() {
    Future.microtask(load);
    return const NuvioState();
  }

  Dio get _dio => ref.read(dioClientProvider);

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_reposKey) ?? const <String>[];
      final repos = <NuvioRepo>[];
      for (final entry in raw) {
        try {
          final decoded = jsonDecode(entry);
          if (decoded is Map) {
            final repo = NuvioRepo.fromJson(Map<String, dynamic>.from(decoded));
            if (repo != null) repos.add(repo);
          }
        } catch (_) {
          // Skip malformed entries.
        }
      }
      state = NuvioState(
        repos: repos,
        enabled: prefs.getBool(_enabledKey) ?? true,
        isLoading: false,
      );
    } catch (error) {
      if (kDebugMode) debugPrint('[Nuvio] load failed: $error');
      state = const NuvioState(repos: [], isLoading: false);
    }
  }

  Future<void> _persist(List<NuvioRepo> repos) async {
    state = state.copyWith(repos: repos, isLoading: false);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _reposKey,
        repos.map((r) => jsonEncode(r.toJson())).toList(),
      );
    } catch (error) {
      if (kDebugMode) debugPrint('[Nuvio] persist failed: $error');
    }
  }

  Future<void> setEnabled(bool value) async {
    state = state.copyWith(enabled: value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, value);
    } catch (_) {
      // Session-only fallback.
    }
  }

  Future<NuvioManifest> fetchManifest(String url) async {
    final response = await _dio.get<dynamic>(
      url,
      options: Options(
        responseType: ResponseType.plain,
        receiveTimeout: const Duration(seconds: 20),
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    if ((response.statusCode ?? 0) >= 400) {
      throw NuvioException('HTTP ${response.statusCode} fetching the manifest.');
    }
    final data = response.data;
    final decoded = data is String ? jsonDecode(data) : data;
    if (decoded is! Map) {
      throw const NuvioException('That URL did not return a JSON manifest.');
    }
    final manifest = NuvioManifest.fromJson(Map<String, dynamic>.from(decoded));
    if (!manifest.isValid) {
      throw const NuvioException(
        'Not a Nuvio plugin manifest (needs name, version and scrapers).',
      );
    }
    return manifest;
  }

  Future<NuvioRepo> addRepository(String rawUrl) async {
    final url = NuvioUrls.normalizeManifestUrl(rawUrl);
    if (url.isEmpty) throw const NuvioException('Enter a plugin manifest URL.');

    final manifest = await fetchManifest(url);
    final repo = NuvioRepo(
      manifestUrl: url,
      manifest: manifest,
      addedAt: DateTime.now(),
    );

    final next = List<NuvioRepo>.of(state.repos);
    final existing = next.indexWhere((r) => r.manifestUrl == url);
    if (existing >= 0) {
      next[existing] = repo.copyWith(
        disabledScrapers: next[existing].disabledScrapers,
      );
    } else {
      next.add(repo);
    }
    await _persist(next);

    // Warm the code cache so the first playback isn't slowed by downloads.
    unawaited(prefetchCode(repo));
    return repo;
  }

  Future<void> removeRepository(String manifestUrl) async {
    await _persist(
      state.repos.where((r) => r.manifestUrl != manifestUrl).toList(),
    );
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().toList()) {
      if (key.startsWith('$_codePrefix$manifestUrl')) {
        await prefs.remove(key);
      }
    }
    _codeCache.removeWhere((key, _) => key.startsWith(manifestUrl));
  }

  Future<void> setScraperEnabled(
    String manifestUrl,
    String scraperId,
    bool enabled,
  ) async {
    final next = [
      for (final repo in state.repos)
        if (repo.manifestUrl != manifestUrl)
          repo
        else
          repo.copyWith(
            disabledScrapers: {
              ...repo.disabledScrapers.where((id) => id != scraperId),
              if (!enabled) scraperId,
            },
          ),
    ];
    await _persist(next);
  }

  Future<void> refreshAll() async {
    if (state.repos.isEmpty) return;
    state = state.copyWith(isLoading: true);
    final refreshed = <NuvioRepo>[];
    for (final repo in state.repos) {
      try {
        final manifest = await fetchManifest(repo.manifestUrl);
        refreshed.add(repo.copyWith(manifest: manifest, clearError: true));
      } catch (error) {
        refreshed.add(repo.copyWith(errorMessage: error.toString()));
      }
    }
    _codeCache.clear();
    await _persist(refreshed);
    for (final repo in refreshed) {
      unawaited(prefetchCode(repo, force: true));
    }
  }

  String _codeKey(String manifestUrl, NuvioScraperInfo scraper) =>
      '$_codePrefix$manifestUrl#${scraper.id}@${scraper.version}';

  /// Scraper source, from memory → disk → network.
  Future<String> codeFor(NuvioRepo repo, NuvioScraperInfo scraper) async {
    final key = _codeKey(repo.manifestUrl, scraper);
    final cached = _codeCache[key];
    if (cached != null) return cached;

    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(key);
    if (stored != null && stored.isNotEmpty) {
      _codeCache[key] = stored;
      return stored;
    }

    final uri = repo.codeUrlFor(scraper);
    if (uri == null) {
      throw NuvioException('${scraper.name} has no usable file name.');
    }

    final response = await _dio.get<dynamic>(
      uri.toString(),
      options: Options(
        responseType: ResponseType.plain,
        receiveTimeout: const Duration(seconds: 25),
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    if ((response.statusCode ?? 0) >= 400) {
      throw NuvioException(
        'HTTP ${response.statusCode} downloading ${scraper.filename}.',
      );
    }
    final code = response.data is String
        ? response.data as String
        : jsonEncode(response.data);
    if (code.trim().isEmpty) {
      throw NuvioException('${scraper.name} returned an empty file.');
    }

    _codeCache[key] = code;
    await prefs.setString(key, code);
    return code;
  }

  Future<void> prefetchCode(NuvioRepo repo, {bool force = false}) async {
    for (final scraper in repo.enabledScrapers) {
      try {
        if (force) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.remove(_codeKey(repo.manifestUrl, scraper));
          _codeCache.remove(_codeKey(repo.manifestUrl, scraper));
        }
        await codeFor(repo, scraper);
      } catch (error) {
        if (kDebugMode) debugPrint('[Nuvio] prefetch ${scraper.id}: $error');
      }
    }
  }
}

class NuvioException implements Exception {
  final String message;
  const NuvioException(this.message);
  @override
  String toString() => message;
}
