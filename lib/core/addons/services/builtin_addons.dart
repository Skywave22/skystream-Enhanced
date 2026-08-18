import '../models/stremio_addon.dart';

/// A built-in, always-available Cinemeta descriptor.
///
/// Stream-only add-ons (Torrentio and friends) publish no catalogs and no
/// metadata, so a user who installs just one of them would otherwise land on
/// an empty Add-ons tab and a detail page that cannot describe anything. This
/// fallback keeps the add-on section self-sufficient — it is still pure
/// Stremio protocol, just not something the user had to install, and it is
/// only consulted when no installed add-on can answer.
class BuiltInAddons {
  const BuiltInAddons._();

  static const String cinemetaUrl = 'https://v3-cinemeta.strem.io/manifest.json';

  static final InstalledAddon cinemeta = InstalledAddon(
    transportUrl: cinemetaUrl,
    installedAt: DateTime.fromMillisecondsSinceEpoch(0),
    manifest: const StremioManifest(
      id: 'com.linvo.cinemeta',
      name: 'Cinemeta',
      version: '3.0.14',
      description: 'Official movie & series catalogs (built-in fallback)',
      types: ['movie', 'series'],
      idPrefixes: ['tt'],
      resources: [
        AddonResourceDefinition(name: 'catalog'),
        AddonResourceDefinition(name: 'meta'),
      ],
      catalogs: [
        AddonCatalogDefinition(
          type: 'movie',
          id: 'top',
          name: 'Popular movies',
          extra: [
            AddonCatalogExtra(name: 'genre'),
            AddonCatalogExtra(name: 'search'),
            AddonCatalogExtra(name: 'skip'),
          ],
        ),
        AddonCatalogDefinition(
          type: 'series',
          id: 'top',
          name: 'Popular series',
          extra: [
            AddonCatalogExtra(name: 'genre'),
            AddonCatalogExtra(name: 'search'),
            AddonCatalogExtra(name: 'skip'),
          ],
        ),
        AddonCatalogDefinition(
          type: 'movie',
          id: 'year',
          name: 'New movies',
          extra: [AddonCatalogExtra(name: 'genre'), AddonCatalogExtra(name: 'skip')],
        ),
        AddonCatalogDefinition(
          type: 'series',
          id: 'year',
          name: 'New series',
          extra: [AddonCatalogExtra(name: 'genre'), AddonCatalogExtra(name: 'skip')],
        ),
        AddonCatalogDefinition(
          type: 'movie',
          id: 'imdbRating',
          name: 'Featured movies',
          extra: [AddonCatalogExtra(name: 'genre'), AddonCatalogExtra(name: 'skip')],
        ),
        AddonCatalogDefinition(
          type: 'series',
          id: 'imdbRating',
          name: 'Featured series',
          extra: [AddonCatalogExtra(name: 'genre'), AddonCatalogExtra(name: 'skip')],
        ),
      ],
    ),
  );
}
