import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/addon_manifest.dart';
import 'addon_client.dart';

part 'addon_repository.g.dart';

class AddonsState {
  final List<ManagedAddon> addons;
  final bool isLoading;

  const AddonsState({this.addons = const [], this.isLoading = true});

  List<ManagedAddon> get enabled =>
      addons.where((a) => a.isActive).toList(growable: false);

  int get catalogCount => enabled.fold(
    0,
    (sum, addon) => sum + (addon.manifest?.catalogs.length ?? 0),
  );

  AddonsState copyWith({List<ManagedAddon>? addons, bool? isLoading}) =>
      AddonsState(
        addons: addons ?? this.addons,
        isLoading: isLoading ?? this.isLoading,
      );
}

/// Owns the user's add-on list: install, enable, order, refresh, persistence.
///
/// Order is priority — the first add-on that answers a request wins, exactly
/// like Stremio and the reference clients.
@Riverpod(keepAlive: true)
class AddonRepository extends _$AddonRepository {
  static const String _prefsKey = 'stremio_addons_v2';

  @override
  AddonsState build() {
    Future.microtask(load);
    return const AddonsState();
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_prefsKey) ?? const <String>[];
      final addons = <ManagedAddon>[];
      for (final entry in raw) {
        try {
          final decoded = jsonDecode(entry);
          if (decoded is Map) {
            final addon = ManagedAddon.fromJson(
              Map<String, dynamic>.from(decoded),
            );
            if (addon != null) addons.add(addon);
          }
        } catch (error) {
          if (kDebugMode) debugPrint('[AddonRepository] bad entry: $error');
        }
      }
      state = AddonsState(addons: addons, isLoading: false);
      // Manifests can change (new catalogs, renamed rows); refresh quietly.
      unawaited(refreshAll(silent: true));
    } catch (error) {
      if (kDebugMode) debugPrint('[AddonRepository] load failed: $error');
      state = const AddonsState(addons: [], isLoading: false);
    }
  }

  Future<void> _persist(List<ManagedAddon> addons) async {
    state = state.copyWith(addons: addons, isLoading: false);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _prefsKey,
        addons.map((a) => jsonEncode(a.toJson())).toList(),
      );
    } catch (error) {
      if (kDebugMode) debugPrint('[AddonRepository] persist failed: $error');
    }
  }

  /// Installs from any pasted URL shape. Throws [AddonException] with a
  /// user-readable message when the manifest can't be used.
  Future<ManagedAddon> install(String rawUrl) async {
    final url = AddonTransport.normalizeManifestUrl(rawUrl);
    if (!AddonTransport.looksValid(url)) {
      throw const AddonException('Enter a valid add-on URL.');
    }

    final manifest = await ref
        .read(addonClientProvider)
        .fetchManifest(url, forceRefresh: true);

    final addon = ManagedAddon(
      manifestUrl: url,
      manifest: manifest,
      addedAt: DateTime.now(),
    );

    final next = List<ManagedAddon>.of(state.addons);
    final existing = next.indexWhere(
      (a) => a.manifestUrl == url || (a.manifest?.id == manifest.id),
    );
    if (existing >= 0) {
      next[existing] = addon.copyWith(enabled: next[existing].enabled);
    } else {
      next.add(addon);
    }
    await _persist(next);
    return addon;
  }

  Future<void> remove(String manifestUrl) async {
    await _persist(
      state.addons.where((a) => a.manifestUrl != manifestUrl).toList(),
    );
  }

  Future<void> setEnabled(String manifestUrl, bool enabled) async {
    await _persist([
      for (final addon in state.addons)
        addon.manifestUrl == manifestUrl
            ? addon.copyWith(enabled: enabled)
            : addon,
    ]);
  }

  /// [newIndex] is already adjusted for the removed row.
  Future<void> reorder(int oldIndex, int newIndex) async {
    final next = List<ManagedAddon>.of(state.addons);
    if (oldIndex < 0 || oldIndex >= next.length) return;
    final addon = next.removeAt(oldIndex);
    next.insert(newIndex.clamp(0, next.length), addon);
    await _persist(next);
  }

  Future<void> refreshAll({bool silent = false}) async {
    if (state.addons.isEmpty) return;
    if (!silent) state = state.copyWith(isLoading: true);

    final client = ref.read(addonClientProvider);
    final refreshed = <ManagedAddon>[];
    for (final addon in state.addons) {
      try {
        final manifest = await client.fetchManifest(
          addon.manifestUrl,
          forceRefresh: true,
        );
        client.invalidate(addon);
        refreshed.add(addon.copyWith(manifest: manifest, clearError: true));
      } catch (error) {
        refreshed.add(addon.copyWith(errorMessage: error.toString()));
      }
    }
    await _persist(refreshed);
  }

  bool isInstalled(String rawUrl) {
    final url = AddonTransport.normalizeManifestUrl(rawUrl);
    return state.addons.any((a) => a.manifestUrl == url);
  }

  /// Enabled add-ons declaring [resource], in user order.
  List<ManagedAddon> providersOf(String resource) => state.enabled
      .where((a) => a.manifest?.hasResource(resource) ?? false)
      .toList(growable: false);
}
