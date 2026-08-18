import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/addons/addon_manager.dart';
import '../../../core/addons/models/addon_meta.dart';
import '../../../core/addons/models/stremio_addon.dart';
import '../../../core/addons/services/addon_client.dart';

part 'addon_catalog_providers.g.dart';

/// One horizontal row on the Add-ons discover screen.
class AddonCatalogRow {
  final InstalledAddon addon;
  final AddonCatalogDefinition definition;
  final List<AddonMetaPreview> items;

  const AddonCatalogRow({
    required this.addon,
    required this.definition,
    required this.items,
  });

  String get title => definition.name.isEmpty
      ? '${addon.name} · ${definition.type}'
      : '${definition.name} · ${addon.name}';

  String get key => '${addon.id}|${definition.uniqueKey}';
}

/// Loads every browsable catalog of every enabled add-on **in parallel**.
///
/// Rows are capped per add-on so a mega-add-on with 30 catalogs can't turn the
/// screen into a hundred requests; the client layer caches results for 15
/// minutes so revisits are instant.
@riverpod
Future<List<AddonCatalogRow>> addonHomeCatalogs(Ref ref) async {
  final addons = ref.watch(addonManagerProvider).enabled;
  final client = ref.watch(addonClientProvider);

  final requests = <Future<AddonCatalogRow?>>[];
  for (final addon in addons) {
    if (!addon.manifest.hasResource('catalog')) continue;
    var perAddon = 0;
    for (final catalog in addon.manifest.catalogs) {
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
            definition: catalog,
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
  return [
    for (final row in rows)
      if (row != null) row,
  ];
}

/// Cross-add-on search over every catalog that advertises `search`.
@riverpod
Future<List<AddonMetaPreview>> addonSearch(Ref ref, String query) async {
  final trimmed = query.trim();
  if (trimmed.length < 2) return const [];

  final addons = ref.watch(addonManagerProvider).enabled;
  final client = ref.watch(addonClientProvider);

  final requests = <Future<List<AddonMetaPreview>>>[];
  for (final addon in addons) {
    if (!addon.manifest.hasResource('catalog')) continue;
    for (final catalog in addon.manifest.catalogs) {
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

/// Full meta for one catalog entry. Falls back to any installed add-on that
/// can answer `meta` for the type/id when the origin add-on cannot.
@riverpod
Future<AddonMeta?> addonMetaDetails(
  Ref ref,
  String type,
  String id, {
  String? preferredAddonId,
}) async {
  final manager = ref.watch(addonManagerProvider.notifier);
  ref.watch(addonManagerProvider);
  final client = ref.watch(addonClientProvider);

  final candidates = manager.providersFor('meta', type, id);
  if (candidates.isEmpty) return null;

  final ordered = [
    ...candidates.where((a) => a.id == preferredAddonId),
    ...candidates.where((a) => a.id != preferredAddonId),
  ];

  for (final addon in ordered) {
    try {
      final meta = await client
          .meta(addon, type: type, id: id)
          .timeout(const Duration(seconds: 12));
      if (meta != null) return meta;
    } catch (_) {
      continue;
    }
  }
  return null;
}

/// The community add-on directory shown in the "Discover add-ons" list.
@riverpod
Future<List<CommunityAddon>> communityAddonDirectory(Ref ref) {
  return ref.watch(addonClientProvider).communityAddons();
}
