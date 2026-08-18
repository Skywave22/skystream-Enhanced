import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/addons/data/addon_client.dart';
import '../../../core/addons/data/addon_repository.dart';
import '../../../core/addons/models/addon_manifest.dart';
import '../../../core/addons/models/addon_meta.dart';

part 'addon_providers.g.dart';

/// One horizontal row of an add-on catalog.
class AddonCatalogRow {
  final ManagedAddon addon;
  final AddonCatalog catalog;
  final List<AddonMetaPreview> items;

  const AddonCatalogRow({
    required this.addon,
    required this.catalog,
    required this.items,
  });

  String get title => '${catalog.name} · ${addon.displayName}';
  String get key => '${addon.manifestUrl}|${catalog.key}';
}

/// Browsable catalogs of every enabled add-on, fetched in parallel.
@riverpod
Future<List<AddonCatalogRow>> addonCatalogRows(Ref ref) async {
  final addons = ref.watch(addonRepositoryProvider).enabled;
  final client = ref.watch(addonClientProvider);

  final requests = <Future<AddonCatalogRow?>>[];
  for (final addon in addons) {
    final manifest = addon.manifest;
    if (manifest == null || !manifest.hasResource('catalog')) continue;

    var perAddon = 0;
    for (final catalog in manifest.catalogs) {
      if (catalog.requiresSearch || catalog.requiresOtherExtra) continue;
      if (perAddon >= 4) break;
      perAddon++;
      requests.add(() async {
        try {
          final items = await client
              .catalog(addon, type: catalog.type, id: catalog.id)
              .timeout(const Duration(seconds: 15));
          if (items.isEmpty) return null;
          return AddonCatalogRow(
            addon: addon,
            catalog: catalog,
            items: items,
          );
        } catch (_) {
          return null;
        }
      }());
    }
  }

  if (requests.isEmpty) return const [];
  final rows = await Future.wait(requests);
  return [for (final row in rows) ?row];
}

/// Search across every catalog that advertises `search`.
@riverpod
Future<List<AddonMetaPreview>> addonSearch(Ref ref, String query) async {
  final trimmed = query.trim();
  if (trimmed.length < 2) return const [];

  final addons = ref.watch(addonRepositoryProvider).enabled;
  final client = ref.watch(addonClientProvider);

  final requests = <Future<List<AddonMetaPreview>>>[];
  for (final addon in addons) {
    final manifest = addon.manifest;
    if (manifest == null || !manifest.hasResource('catalog')) continue;
    for (final catalog in manifest.catalogs) {
      if (!catalog.supportsSearch) continue;
      requests.add(() async {
        try {
          return await client
              .catalog(
                addon,
                type: catalog.type,
                id: catalog.id,
                extra: {'search': trimmed},
              )
              .timeout(const Duration(seconds: 12));
        } catch (_) {
          return const <AddonMetaPreview>[];
        }
      }());
    }
  }

  if (requests.isEmpty) return const [];
  final results = await Future.wait(requests);

  final seen = <String>{};
  final out = <AddonMetaPreview>[];
  for (final list in results) {
    for (final item in list) {
      if (seen.add('${item.type}:${item.id}')) out.add(item);
    }
  }
  return out;
}

/// Meta for one item: the add-on it came from first, then any other meta
/// add-on that accepts the id.
@riverpod
Future<AddonMeta?> addonMeta(
  Ref ref,
  String type,
  String id, {
  String? preferredAddonUrl,
}) async {
  final addons = ref.watch(addonRepositoryProvider).enabled;
  final client = ref.watch(addonClientProvider);

  final candidates = addons
      .where((a) => a.manifest?.hasResource('meta') ?? false)
      .toList();
  if (candidates.isEmpty) return null;

  final ordered = [
    ...candidates.where((a) => a.manifestUrl == preferredAddonUrl),
    ...candidates.where((a) => a.manifestUrl != preferredAddonUrl),
  ];

  for (final addon in ordered) {
    final manifest = addon.manifest!;
    if (!manifest.supportsId('meta', id)) continue;
    for (final requestType in manifest.requestTypesFor('meta', type)) {
      try {
        final meta = await client
            .meta(addon, type: requestType, id: id)
            .timeout(const Duration(seconds: 12));
        if (meta != null) return meta;
      } catch (_) {
        continue;
      }
    }
  }
  return null;
}

/// Stremio's community add-on directory (Discover tab).
@riverpod
Future<List<CommunityAddon>> communityAddons(Ref ref) {
  return ref.watch(addonClientProvider).communityAddons();
}
