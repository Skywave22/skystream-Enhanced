import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/nuvio/data/nuvio_repository.dart';
import '../../../core/nuvio/models/nuvio_models.dart';

/// Manage Nuvio-format plugin repositories.
///
/// Nuvio plugins are JS scrapers listed in a manifest; SkyStream runs them
/// next to its own plugins and merges the links they return into the same
/// sources sheet.
class NuvioPluginsView extends ConsumerStatefulWidget {
  const NuvioPluginsView({super.key});

  @override
  ConsumerState<NuvioPluginsView> createState() => _NuvioPluginsViewState();
}

class _NuvioPluginsViewState extends ConsumerState<NuvioPluginsView> {
  bool _busy = false;

  Future<void> _addRepository() async {
    // Captured before the dialog await so the context isn't used across gaps.
    final messenger = ScaffoldMessenger.of(context);
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add Nuvio plugin repository'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Paste the plugin manifest URL (the JSON listing "scrapers"). '
              'A bare host works too.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                hintText: 'https://example.com/plugins/manifest.json',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: 'Paste',
                  icon: const Icon(Icons.content_paste_rounded),
                  onPressed: () async {
                    final data = await Clipboard.getData('text/plain');
                    final text = data?.text;
                    if (text != null) controller.text = text.trim();
                  },
                ),
              ),
              onSubmitted: (value) =>
                  Navigator.pop(dialogContext, value.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (url == null || url.isEmpty) return;

    setState(() => _busy = true);
    try {
      final repo = await ref
          .read(nuvioRepositoryProvider.notifier)
          .addRepository(url);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Added ${repo.displayName} · '
            '${repo.manifest?.scrapers.length ?? 0} scrapers',
          ),
        ),
      );
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(nuvioRepositoryProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.extension_rounded, color: cs.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Nuvio plugins',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Switch(
                      value: state.enabled,
                      onChanged: (value) => unawaited(
                        ref
                            .read(nuvioRepositoryProvider.notifier)
                            .setEnabled(value),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Scraper plugins in Nuvio\'s format. Their links appear in '
                  'the same sources sheet as SkyStream plugins, tagged NUVIO.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: _busy ? null : () => unawaited(_addRepository()),
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.add_link_rounded),
                      label: const Text('Add repository'),
                    ),
                    const SizedBox(width: 10),
                    if (state.repos.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: () => unawaited(
                          ref.read(nuvioRepositoryProvider.notifier).refreshAll(),
                        ),
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Refresh'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (state.isLoading && state.repos.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (!state.isLoading && state.repos.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
            child: Text(
              'No Nuvio repositories yet. Add one and its scrapers will start '
              'contributing links to Explore playback.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        for (final repo in state.repos) _RepoCard(repo: repo),
      ],
    );
  }
}

class _RepoCard extends ConsumerWidget {
  final NuvioRepo repo;
  const _RepoCard({required this.repo});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final manifest = repo.manifest;
    final scrapers = manifest?.scrapers ?? const <NuvioScraperInfo>[];

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        repo.displayName,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '${manifest?.version ?? '?'} · '
                        '${scrapers.length} scrapers',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => unawaited(
                    ref
                        .read(nuvioRepositoryProvider.notifier)
                        .removeRepository(repo.manifestUrl),
                  ),
                ),
              ],
            ),
            if (repo.errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(right: 8, bottom: 6),
                child: Text(
                  repo.errorMessage!,
                  style: theme.textTheme.labelSmall?.copyWith(color: cs.error),
                ),
              ),
            for (final scraper in scrapers)
              SwitchListTile(
                dense: true,
                contentPadding: const EdgeInsets.only(right: 4),
                value: repo.isScraperEnabled(scraper),
                onChanged: scraper.manifestEnabled
                    ? (value) => unawaited(
                        ref
                            .read(nuvioRepositoryProvider.notifier)
                            .setScraperEnabled(
                              repo.manifestUrl,
                              scraper.id,
                              value,
                            ),
                      )
                    : null,
                title: Text(
                  scraper.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                subtitle: Text(
                  [
                    'v${scraper.version}',
                    scraper.supportedTypes.join('/'),
                    if (scraper.contentLanguage.isNotEmpty)
                      scraper.contentLanguage.join(', '),
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
