import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/addons/addon_manager.dart';
import '../../../core/addons/models/addon_meta.dart';
import '../../../core/router/app_router.dart';
import '../../../core/utils/layout_constants.dart';
import 'addon_catalog_providers.dart';
import 'widgets/addon_manage_view.dart';

/// Top-level "Add-ons" destination — the tab that replaced Stream.
///
/// Three tabs: browse everything the installed add-ons publish, manage the
/// installed list, and discover new add-ons from Stremio's community index.
class AddonsScreen extends ConsumerStatefulWidget {
  const AddonsScreen({super.key});

  @override
  ConsumerState<AddonsScreen> createState() => _AddonsScreenState();
}

class _AddonsScreenState extends ConsumerState<AddonsScreen> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Add-ons'),
          bottom: TabBar(
            indicatorSize: TabBarIndicatorSize.label,
            labelColor: theme.colorScheme.primary,
            unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
            indicatorColor: theme.colorScheme.primary,
            tabs: const [
              Tab(text: 'Catalogs'),
              Tab(text: 'My add-ons'),
              Tab(text: 'Discover'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _CatalogsTab(
              query: _query,
              controller: _searchController,
              onQueryChanged: _onQueryChanged,
            ),
            const AddonManageView(),
            const _DirectoryTab(),
          ],
        ),
      ),
    );
  }
}

class _CatalogsTab extends ConsumerWidget {
  final String query;
  final TextEditingController controller;
  final ValueChanged<String> onQueryChanged;

  const _CatalogsTab({
    required this.query,
    required this.controller,
    required this.onQueryChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final addons = ref.watch(addonManagerProvider);
    final theme = Theme.of(context);

    if (!addons.isLoading && addons.enabled.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.dashboard_customize_outlined,
                size: 52,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 14),
              Text('No add-ons enabled', style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                'Install add-ons in the "My add-ons" tab to browse their '
                'catalogs and stream from them.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: controller,
            onChanged: onQueryChanged,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search across your add-ons…',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: controller.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        controller.clear();
                        onQueryChanged('');
                      },
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              isDense: true,
            ),
          ),
        ),
        Expanded(
          child: query.length >= 2
              ? _SearchResults(query: query)
              : const _CatalogRows(),
        ),
      ],
    );
  }
}

class _CatalogRows extends ConsumerWidget {
  const _CatalogRows();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rowsAsync = ref.watch(addonHomeCatalogsProvider);

    return rowsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Could not load catalogs: $error'),
        ),
      ),
      data: (rows) {
        if (rows.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Your add-ons published no browsable catalogs. '
                'Cinemeta is a good place to start.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(addonHomeCatalogsProvider);
            await ref.read(addonHomeCatalogsProvider.future);
          },
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 90),
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final row = rows[index];
              return _CatalogRow(row: row);
            },
          ),
        );
      },
    );
  }
}

class _CatalogRow extends StatelessWidget {
  final AddonCatalogRow row;
  const _CatalogRow({required this.row});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            LayoutConstants.spacingMd,
            LayoutConstants.spacingMd,
            LayoutConstants.spacingMd,
            LayoutConstants.spacingSm,
          ),
          child: Text(
            row.title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        SizedBox(
          height: 218,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: LayoutConstants.spacingMd,
            ),
            itemCount: row.items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) => AddonPosterCard(
              item: row.items[index],
              addonId: row.addon.id,
            ),
          ),
        ),
      ],
    );
  }
}

class _SearchResults extends ConsumerWidget {
  final String query;
  const _SearchResults({required this.query});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resultsAsync = ref.watch(addonSearchProvider(query));

    return resultsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(child: Text('Search failed: $error')),
      data: (items) {
        if (items.isEmpty) {
          return const Center(child: Text('Nothing found in your add-ons.'));
        }
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 90),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 140,
            childAspectRatio: 0.55,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) => AddonPosterCard(
            item: items[index],
            addonId: items[index].addonId,
            width: double.infinity,
          ),
        );
      },
    );
  }
}

/// Poster tile used by both the catalog rows and search results.
class AddonPosterCard extends StatelessWidget {
  final AddonMetaPreview item;
  final String addonId;
  final double width;

  const AddonPosterCard({
    super.key,
    required this.item,
    required this.addonId,
    this.width = 124,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      width: width == double.infinity ? null : width,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          AddonDetailRoute(
            type: item.type,
            id: item.id,
            addonId: addonId,
          ).push<void>(context);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: item.poster == null
                    ? ColoredBox(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: const Center(child: Icon(Icons.movie_outlined)),
                      )
                    : CachedNetworkImage(
                        imageUrl: item.poster!,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        errorWidget: (_, _, _) => ColoredBox(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: const Center(
                            child: Icon(Icons.broken_image_outlined),
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (item.releaseInfo != null)
              Text(
                item.releaseInfo!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DirectoryTab extends ConsumerWidget {
  const _DirectoryTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final directoryAsync = ref.watch(communityAddonDirectoryProvider);
    final installed = ref.watch(addonManagerProvider).addons;
    final installedIds = installed.map((a) => a.id).toSet();

    return directoryAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Could not load the add-on directory: $error'),
        ),
      ),
      data: (entries) {
        if (entries.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'The community directory is unavailable right now. You can '
                'still paste a manifest URL in "My add-ons".',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final entry = entries[index];
            final isInstalled = installedIds.contains(entry.manifest.id);
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: ListTile(
                leading: entry.manifest.logo != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CachedNetworkImage(
                          imageUrl: entry.manifest.logo!,
                          width: 38,
                          height: 38,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) =>
                              const Icon(Icons.extension_rounded),
                        ),
                      )
                    : const Icon(Icons.extension_rounded),
                title: Text(entry.manifest.name),
                subtitle: Text(
                  entry.manifest.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: isInstalled
                    ? const Icon(Icons.check_circle_rounded, color: Colors.green)
                    : IconButton(
                        icon: const Icon(Icons.add_circle_outline_rounded),
                        tooltip: 'Install',
                        onPressed: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          try {
                            await ref
                                .read(addonManagerProvider.notifier)
                                .install(entry.transportUrl);
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Installed ${entry.manifest.name}',
                                ),
                              ),
                            );
                          } catch (error) {
                            messenger.showSnackBar(
                              SnackBar(content: Text('Install failed: $error')),
                            );
                          }
                        },
                      ),
              ),
            );
          },
        );
      },
    );
  }
}
