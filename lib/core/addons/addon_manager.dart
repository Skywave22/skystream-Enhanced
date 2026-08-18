import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/stremio_addon.dart';
import 'services/addon_client.dart';

part 'addon_manager.g.dart';

/// Immutable snapshot of the user's add-on library.
class AddonsState {
  final List<InstalledAddon> addons;
  final bool isLoading;
  final String? error;

  const AddonsState({
    this.addons = const [],
    this.isLoading = true,
    this.error,
  });

  List<InstalledAddon> get enabled =>
      addons.where((a) => a.enabled).toList(growable: false);

  bool get isEmpty => addons.isEmpty;

  AddonsState copyWith({
    List<InstalledAddon>? addons,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return AddonsState(
      addons: addons ?? this.addons,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Owns the installed Stremio add-ons: persistence, ordering, enable state and
/// the resource-aware lookups the rest of the app fans out over.
@Riverpod(keepAlive: true)
class AddonManager extends _$AddonManager {
  static const String _prefsKey = 'stremio_addons_v1';

  @override
  AddonsState build() {
    Future.microtask(load);
    return const AddonsState();
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_prefsKey) ?? const <String>[];
      final addons = <InstalledAddon>[];
      for (final entry in raw) {
        try {
          final decoded = jsonDecode(entry);
          if (decoded is Map) {
            final addon = InstalledAddon.fromJson(
              Map<String, dynamic>.from(decoded),
            );
            if (addon != null) addons.add(addon);
          }
        } catch (error) {
          if (kDebugMode) debugPrint('[AddonManager] bad entry: $error');
        }
      }
      state = AddonsState(addons: addons, isLoading: false);
    } catch (error) {
      state = AddonsState(
        addons: const [],
        isLoading: false,
        error: error.toString(),
      );
    }
  }

  Future<void> _persist(List<InstalledAddon> addons) async {
    state = state.copyWith(addons: addons, isLoading: false, clearError: true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _prefsKey,
        addons.map((a) => jsonEncode(a.toJson())).toList(),
      );
    } catch (error) {
      if (kDebugMode) debugPrint('[AddonManager] persist failed: $error');
    }
  }

  /// Installs (or upgrades) an add-on from any manifest URL shape.
  Future<InstalledAddon> install(String url) async {
    final normalized = AddonUrl.normalize(url);
    if (!AddonUrl.looksValid(normalized)) {
      throw const AddonException('Enter a valid add-on URL.');
    }

    final client = ref.read(addonClientProvider);
    final manifest = await client.fetchManifest(normalized, forceRefresh: true);

    final addon = InstalledAddon(
      transportUrl: normalized,
      manifest: manifest,
      installedAt: DateTime.now(),
    );

    final next = List<InstalledAddon>.of(state.addons);
    final existing = next.indexWhere(
      (a) => a.id == addon.id || a.transportUrl == addon.transportUrl,
    );
    if (existing >= 0) {
      next[existing] = addon.copyWith(enabled: next[existing].enabled);
    } else {
      next.add(addon);
    }
    await _persist(next);
    return addon;
  }

  Future<void> remove(String id) async {
    final next = state.addons.where((a) => a.id != id).toList();
    await _persist(next);
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final next = [
      for (final addon in state.addons)
        addon.id == id ? addon.copyWith(enabled: enabled) : addon,
    ];
    await _persist(next);
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    final next = List<InstalledAddon>.of(state.addons);
    if (oldIndex < 0 || oldIndex >= next.length) return;
    var target = newIndex;
    if (target > oldIndex) target -= 1;
    target = target.clamp(0, next.length - 1);
    final addon = next.removeAt(oldIndex);
    next.insert(target, addon);
    await _persist(next);
  }

  /// Re-downloads every manifest so renamed catalogs / new resources appear
  /// without the user having to reinstall.
  Future<void> refreshAll() async {
    if (state.addons.isEmpty) return;
    state = state.copyWith(isLoading: true);
    final client = ref.read(addonClientProvider);
    final refreshed = <InstalledAddon>[];
    for (final addon in state.addons) {
      try {
        final manifest = await client.fetchManifest(
          addon.transportUrl,
          forceRefresh: true,
        );
        refreshed.add(addon.copyWith(manifest: manifest));
        client.invalidateAddon(addon);
      } catch (_) {
        refreshed.add(addon);
      }
    }
    await _persist(refreshed);
  }

  bool isInstalled(String idOrUrl) {
    final normalized = AddonUrl.normalize(idOrUrl);
    return state.addons.any(
      (a) => a.id == idOrUrl || a.transportUrl == normalized,
    );
  }

  /// Enabled add-ons that declare `resource` for `type` (and optionally an id
  /// prefix). Order follows the user's list, which doubles as priority.
  List<InstalledAddon> providersFor(
    String resource,
    String type, [
    String? id,
  ]) {
    return state.enabled
        .where((a) => a.manifest.supports(resource, type, id))
        .toList(growable: false);
  }

  List<InstalledAddon> get catalogAddons => state.enabled
      .where((a) => a.manifest.hasResource('catalog'))
      .toList(growable: false);
}

/// Convenience selector so widgets can watch just the enabled list.
@Riverpod(keepAlive: true)
List<InstalledAddon> enabledAddons(Ref ref) {
  return ref.watch(addonManagerProvider).enabled;
}
