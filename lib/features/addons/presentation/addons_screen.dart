import 'package:flutter/material.dart';

/// Add-ons destination.
///
/// This tab is the home of the Stremio add-on system. It is intentionally
/// isolated from the plugin/extension pipeline: nothing here reads installed
/// plugins, and no plugin code path can feed content into it.
///
/// Right now it only hosts the empty state — install/manage, catalogs and
/// add-on powered playback land here next.
class AddonsScreen extends StatelessWidget {
  const AddonsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Add-ons')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.dashboard_customize_outlined,
                  size: 56,
                  color: cs.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  'Add-ons',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Stremio-style add-ons will live here — catalogs, metadata, '
                  'streams and subtitles served straight from the add-ons you '
                  'install. Plugins are not involved in this section.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
