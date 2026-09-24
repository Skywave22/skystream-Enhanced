import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/models/addon_manifest.dart';

bool addonMatches(ManagedAddon addon, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  final haystack = [
    addon.displayName,
    addon.manifest?.id ?? '',
    addon.manifestUrl,
    addon.manifest?.description ?? '',
    if (addon.manifest != null) ...addon.manifest!.types,
    if (addon.manifest != null)
      for (final r in addon.manifest!.resources) r.name,
  ].join(' ').toLowerCase();
  return haystack.contains(q);
}

void main() {
  test('matches display name and id', () {
    final addon = ManagedAddon(
      manifestUrl: 'https://torrentio.strem.fun/manifest.json',
      addedAt: DateTime.utc(2024, 1, 1),
      manifest: const AddonManifest(
        id: 'com.stremio.torrentio',
        name: 'Torrentio',
        version: '1.0.0',
        description: 'Torrent streams',
        types: ['movie', 'series'],
        resources: [AddonResource(name: 'stream')],
      ),
    );
    expect(addonMatches(addon, ''), isTrue);
    expect(addonMatches(addon, 'torrentio'), isTrue);
    expect(addonMatches(addon, 'strem.fun'), isTrue);
    expect(addonMatches(addon, 'stream'), isTrue);
    expect(addonMatches(addon, 'cinemeta'), isFalse);
  });
}
