import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cloudstream/cloudstream_engine.dart';
import '../../../core/cloudstream/cloudstream_models.dart';
import '../../../core/cloudstream/cloudstream_repository.dart';
import '../../../core/logger/app_logger.dart';
import '../../../core/models/extension_update_report.dart' show toastNames;
import '../../../core/router/app_router.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/custom_widgets.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/text_input_dialog.dart';
import 'extension_ui/extension_settings_flow.dart';

/// Settings → CloudStream Extensions: the global switch, repositories, and installed plugins.
class CloudStreamScreen extends ConsumerWidget {
  const CloudStreamScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        // Its fields are in dialogs and sheets above it, which make room for the keyboard themselves; a
        // small phone's keyboard would otherwise squeeze the header out of the screen behind them.
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: () {
              if (Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              } else {
                const SettingsRoute().go(context);
              }
            },
          ),
          title: Text(l10n.cloudStreamExtensions),
          bottom: TabBar(
            tabs: [
              Tab(text: l10n.installed),
              Tab(text: l10n.repositories),
            ],
          ),
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            // A D-pad (TV) moves through the screen in reading order.
            child: FocusTraversalGroup(
              policy: ReadingOrderTraversalPolicy(),
              child: const Column(
                children: [
                  _Header(),
                  Expanded(child: TabBarView(children: [_InstalledTab(), _RepositoriesTab()])),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends ConsumerStatefulWidget {
  const _Header();

  @override
  ConsumerState<_Header> createState() => _HeaderState();
}

class _HeaderState extends ConsumerState<_Header> {
  bool _adding = false;
  bool _refreshing = false;
  bool _updating = false;

  Future<void> _addRepository() async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    final url = await TextInputDialog.show(
      context,
      title: l10n.cloudStreamAddRepositoryTitle,
      message: l10n.cloudStreamAddRepositoryMessage,
      hintText: l10n.repoUrlOrShortcode,
      keyboardType: TextInputType.url,
      confirmLabel: l10n.cloudStreamAdd,
      showPasteButton: true,
      width: 480,
    );
    if (url == null || url.isEmpty) return;
    setState(() => _adding = true);
    try {
      final repo = await ref.read(cloudStreamRepositoryProvider.notifier).addRepository(url);
      messenger.showSnackBar(SnackBar(content: Text(l10n.cloudStreamRepositoryAdded(repo.plugins.length, repo.name))));
      if (mounted) DefaultTabController.of(context).animateTo(1);
    } catch (error, stack) {
      talker.error('[CloudStream] adding repository $url failed', error, stack);
      messenger.showSnackBar(SnackBar(content: Text(l10n.cloudStreamCouldNotAdd(CloudStreamRepository.errorMessage(error)))));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _refresh() async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    setState(() => _refreshing = true);
    try {
      final failed = await ref.read(cloudStreamRepositoryProvider.notifier).refreshAll();
      final state = ref.read(cloudStreamRepositoryProvider);
      final updates = state.installed.where((p) => state.updateFor(p) != null).length;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            [
              if (updates == 0) l10n.cloudStreamUpToDate else l10n.cloudStreamUpdatesAvailable(updates),
              if (failed.isNotEmpty) l10n.cloudStreamCouldNotCheck(failed.join(', ')),
            ].join(' · '),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  /// Brings every installed extension up to date in one go: the repositories are checked again and
  /// each extension with a newer version is installed over the old one.
  Future<void> _updateAll() async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    setState(() => _updating = true);
    try {
      final report = await ref.read(cloudStreamRepositoryProvider.notifier).autoUpdate();
      final updated = report.updated;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            [
              if (updated.isEmpty) l10n.cloudStreamUpToDate else l10n.extensionsUpdated(updated.length),
              if (updated.isNotEmpty) toastNames(updated),
            ].join(' · '),
          ),
        ),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.cloudStreamFailed(CloudStreamRepository.errorMessage(error)))),
      );
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(cloudStreamRepositoryProvider);
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final updates = state.installed.where((p) => state.updateFor(p) != null).length;

    return Card(
      margin: const EdgeInsets.fromLTRB(
        LayoutConstants.spacingMd,
        LayoutConstants.spacingMd,
        LayoutConstants.spacingMd,
        LayoutConstants.spacingXs,
      ),
      child: Padding(
        padding: const EdgeInsets.all(LayoutConstants.spacingMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: cs.tertiaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.cloud_rounded, color: cs.onTertiaryContainer, size: 22),
                ),
                const SizedBox(width: LayoutConstants.spacingSm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.cloudStream,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, color: cs.primary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        state.enabled ? l10n.cloudStreamOn : l10n.cloudStreamOff,
                        style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: LayoutConstants.spacingXs),
                // Identifiers for UI tests (Maestro reads Semantics, not keys).
                Semantics(
                  identifier: 'cs3-cloudstream-switch',
                  child: CustomSwitch(
                    key: const ValueKey('cs3_cloudstream_switch'),
                    value: state.enabled,
                    onChanged: (value) => unawaited(ref.read(cloudStreamRepositoryProvider.notifier).setEnabled(value)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: LayoutConstants.spacingMd),
            SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: LayoutConstants.spacingSm,
                runSpacing: LayoutConstants.spacingXs,
                children: [
                  if (state.repositories.isNotEmpty)
                    CustomButton(
                      isOutlined: true,
                      onPressed: _refreshing ? null : () => unawaited(_refresh()),
                      child: _ButtonLabel(
                        busy: _refreshing,
                        icon: Icons.refresh_rounded,
                        text: _refreshing
                            ? l10n.cloudStreamChecking
                            : (updates > 0 ? l10n.cloudStreamCheckUpdatesCount(updates) : l10n.cloudStreamCheckUpdates),
                      ),
                    ),
                  // Updates every installed extension at once, not one extension at a time.
                  if (state.installed.isNotEmpty)
                    CustomButton(
                      isOutlined: true,
                      onPressed: _updating ? null : () => unawaited(_updateAll()),
                      child: _ButtonLabel(
                        busy: _updating,
                        icon: Icons.system_update_alt_rounded,
                        text: _updating ? l10n.cloudStreamUpdatingAll : l10n.cloudStreamUpdateAll,
                      ),
                    ),
                  CustomButton(
                    isPrimary: true,
                    onPressed: _adding ? null : () => unawaited(_addRepository()),
                    child: _ButtonLabel(busy: _adding, icon: Icons.add_circle_outline, text: l10n.addRepository),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ButtonLabel extends StatelessWidget {
  const _ButtonLabel({required this.busy, required this.icon, required this.text});

  final bool busy;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (busy)
        const SizedBox(
          width: 16,
          height: 16,
          child: AppLoadingIndicator(constraints: BoxConstraints(maxWidth: 16, maxHeight: 16)),
        )
      else
        Icon(icon, size: 18),
      const SizedBox(width: 8),
      Text(text),
    ],
  );
}

class _InstalledTab extends ConsumerStatefulWidget {
  const _InstalledTab();

  @override
  ConsumerState<_InstalledTab> createState() => _InstalledTabState();
}

class _InstalledTabState extends ConsumerState<_InstalledTab> {
  @override
  void initState() {
    super.initState();
    // Extensions installed before this version haven't said whether they have a settings screen.
    unawaited(ref.read(cloudStreamRepositoryProvider.notifier).learnSettings());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(cloudStreamRepositoryProvider);
    if (state.isLoading) return const Center(child: AppLoadingIndicator());
    if (state.installed.isEmpty) {
      final l10n = AppLocalizations.of(context)!;
      return _Empty(
        icon: Icons.extension_off_outlined,
        title: l10n.noExtensionsInstalled,
        message: l10n.browseRepositoriesToInstall,
      );
    }
    return ListView.separated(
      padding: EdgeInsets.only(bottom: LayoutConstants.shellBottomContentPadding(context)),
      itemCount: state.installed.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
      itemBuilder: (context, index) {
        final plugin = state.installed[index];
        return _PluginTile(info: plugin.info, installed: plugin);
      },
    );
  }
}

class _RepositoriesTab extends ConsumerWidget {
  const _RepositoriesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(cloudStreamRepositoryProvider);
    if (state.isLoading) return const Center(child: AppLoadingIndicator());
    if (state.repositories.isEmpty) {
      final l10n = AppLocalizations.of(context)!;
      return _Empty(
        icon: Icons.snippet_folder_outlined,
        title: l10n.cloudStreamNoRepositories,
        message: l10n.addRepoDescription,
      );
    }
    return ListView(
      padding: EdgeInsets.only(bottom: LayoutConstants.shellBottomContentPadding(context)),
      children: [for (final repo in state.repositories) _RepositoryCard(repo: repo)],
    );
  }
}

class _RepositoryCard extends ConsumerWidget {
  const _RepositoryCard({required this.repo});

  final CsRepository repo;

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.removeRepoConfirm(repo.name)),
        content: Text(l10n.removeRepoWarning),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(l10n.cancel)),
          TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(l10n.cloudStreamRemove)),
        ],
      ),
    );
    if (remove != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(cloudStreamRepositoryProvider.notifier).removeRepository(repo.url);
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.cloudStreamCouldNotRemove(repo.name, CloudStreamRepository.errorMessage(error)))),
      );
    }
  }

  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    final failure = await ref.read(cloudStreamRepositoryProvider.notifier).refreshRepository(repo.url);
    if (failure != null) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.cloudStreamCouldNotCheckRepository(repo.name, failure))));
    }
  }

  /// Installs every extension of this repository that is not installed yet: a repository lists
  /// dozens, and installing them one by one is a tap each.
  Future<void> _installAll(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    try {
      final result = await ref.read(cloudStreamRepositoryProvider.notifier).installAll(repo);
      final message = [
        if (result.installed.isNotEmpty) l10n.cloudStreamInstalledAll(result.installed.length),
        if (result.failed.isNotEmpty) l10n.cloudStreamCouldNotInstallAll(result.failed.join(', ')),
      ].join(' · ');
      if (message.isNotEmpty) {
        messenger.showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.cloudStreamFailed(CloudStreamRepository.errorMessage(error)))),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(cloudStreamRepositoryProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final installedCount = repo.plugins.where((p) => state.installedFor(p) != null).length;
    final missing = repo.plugins.length - installedCount;
    final busy = repo.plugins.any((p) => state.busy.contains(CloudStreamRepository.keyOf(p)));
    final l10n = AppLocalizations.of(context)!;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: LayoutConstants.spacingMd, vertical: LayoutConstants.spacingXs),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: PageStorageKey('cs3_repo_${repo.url}'),
        shape: const Border(),
        collapsedShape: const Border(),
        initiallyExpanded: repo.plugins.length <= 12,
        title: Text(
          repo.name,
          style: theme.textTheme.titleMedium?.copyWith(color: cs.primary, fontWeight: FontWeight.bold),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          [
            l10n.cloudStreamRepositorySummary(repo.plugins.length, installedCount),
            if (repo.error != null) l10n.cloudStreamLastCheckFailed,
          ].join(' · '),
          style: theme.textTheme.bodySmall?.copyWith(color: repo.error != null ? cs.error : cs.onSurfaceVariant),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: LayoutConstants.spacingSm),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    repo.url,
                    style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: l10n.cloudStreamRefreshRepository,
                  icon: const Icon(Icons.refresh_rounded),
                  onPressed: () => unawaited(_refresh(context, ref)),
                ),
                // Installs every extension this repository lists that is not installed yet.
                if (missing > 0)
                  IconButton(
                    tooltip: l10n.cloudStreamInstallAll,
                    icon: const Icon(Icons.download_for_offline_outlined),
                    onPressed: busy ? null : () => unawaited(_installAll(context, ref)),
                  ),
                IconButton(
                  tooltip: l10n.removeRepository,
                  icon: Icon(Icons.delete_outline, color: cs.error),
                  onPressed: () => unawaited(_confirmRemove(context, ref)),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          for (final plugin in repo.plugins)
            _PluginTile(info: plugin, installed: state.installedFor(plugin)),
        ],
      ),
    );
  }
}

class _PluginTile extends ConsumerWidget {
  const _PluginTile({required this.info, required this.installed});

  final CsPluginInfo info;
  final CsInstalledPlugin? installed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed = this.installed;
    final key = CloudStreamRepository.keyOf(info);
    // Only what this tile shows: a repository's tiles otherwise all rebuild on every change.
    final busy = ref.watch(cloudStreamRepositoryProvider.select((s) => s.busy.contains(key)));
    final applying = ref.watch(cloudStreamRepositoryProvider.select((s) => s.applying.contains(key)));
    final newer = installed == null
        ? null
        : ref.watch(cloudStreamRepositoryProvider.select((s) => s.updateFor(installed)));
    final hasPopups =
        installed != null && ref.watch(cloudStreamRepositoryProvider.select((s) => s.popupsFor(installed).isNotEmpty));
    // Switched off, CloudStream loads no extension: what would load one waits for the switch (Uninstall doesn't).
    final on = ref.watch(cloudStreamRepositoryProvider.select((s) => s.enabled));
    final notifier = ref.read(cloudStreamRepositoryProvider.notifier);
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final status = switch (info.status) {
      0 => l10n.cloudStreamStatusDown,
      2 => l10n.cloudStreamStatusSlow,
      3 => l10n.cloudStreamStatusBeta,
      _ => null,
    };

    final details = [
      if (info.tvTypes.isNotEmpty) info.tvTypes.take(3).join(' / '),
      if (info.language != null && info.language!.isNotEmpty) info.language!.toUpperCase(),
      if (info.authors.isNotEmpty) info.authors.take(2).join(', '),
      if (info.fileSize case final size? when size > 0) _size(size),
    ].join(' · ');

    final providers = installed?.providers.map((p) => p.name).join(', ');

    return ListTile(
      key: ValueKey('cs3_plugin_${CloudStreamRepository.keyOf(info)}'),
      leading: _PluginIcon(url: info.iconUrl, name: info.name),
      title: Row(
        children: [
          Flexible(child: Text(info.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 6),
          _Chip(text: newer != null ? 'v${installed?.info.version} → v${newer.version}' : 'v${installed?.info.version ?? info.version}',
              color: newer != null ? cs.tertiary : cs.outline),
          if (status != null) ...[
            const SizedBox(width: 4),
            _Chip(text: status, color: info.isDown ? cs.error : cs.outline),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (details.isNotEmpty) Text(details, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (providers != null && providers.isNotEmpty)
            Text(l10n.cloudStreamProviders(providers), maxLines: 1, overflow: TextOverflow.ellipsis),
          if (installed?.loadError != null)
            Text(
              l10n.cloudStreamCouldNotLoad(installed!.loadError!),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cs.error),
            ),
          if (applying) Text(l10n.cloudStreamSettingsApplying, style: TextStyle(color: cs.primary)),
        ],
      ),
      trailing: busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: AppLoadingIndicator(constraints: BoxConstraints(maxWidth: 24, maxHeight: 24)),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (installed == null)
                  // Identifiers for UI tests (Maestro reads Semantics, not keys).
                  Semantics(
                    identifier: 'cs3-install-${info.internalName}',
                    child: IconButton(
                      key: ValueKey('cs3_install_${info.internalName}'),
                      tooltip: l10n.install,
                      icon: const Icon(Icons.download_rounded),
                      onPressed: on
                          ? () => unawaited(_install(context, () => notifier.install(info), l10n.cloudStreamInstalled))
                          : null,
                    ),
                  )
                else ...[
                  if (hasPopups && extensionScreensSupported && on)
                    Semantics(
                      identifier: 'cs3-support-${info.internalName}',
                      child: IconButton(
                        key: ValueKey('cs3_support_${info.internalName}'),
                        tooltip: l10n.cloudStreamSupport,
                        icon: Icon(Icons.volunteer_activism_rounded, color: cs.tertiary),
                        onPressed: () => unawaited(openExtensionPopups(context, ref, installed)),
                      ),
                    ),
                  if (installed.hasSettings == true && extensionScreensSupported)
                    Semantics(
                      identifier: 'cs3-settings-${info.internalName}',
                      child: IconButton(
                        key: ValueKey('cs3_settings_${info.internalName}'),
                        tooltip: l10n.cloudStreamSettings,
                        icon: const Icon(Icons.tune_rounded),
                        onPressed: applying || !on
                            ? null
                            : () => unawaited(openExtensionSettings(context, ref, installed)),
                      ),
                    ),
                  if (newer != null)
                    IconButton(
                      tooltip: l10n.cloudStreamUpdate,
                      icon: Icon(Icons.system_update_alt_rounded, color: cs.tertiary),
                      onPressed: on
                          ? () => unawaited(_install(context, () => notifier.install(newer), l10n.cloudStreamUpdated))
                          : null,
                    ),
                  Semantics(
                    identifier: 'cs3-uninstall-${info.internalName}',
                    child: IconButton(
                      key: ValueKey('cs3_uninstall_${info.internalName}'),
                      tooltip: l10n.cloudStreamUninstall,
                      icon: Icon(Icons.delete_outline, color: cs.error),
                      onPressed: () => unawaited(_run(context, () => notifier.uninstall(installed), l10n.cloudStreamUninstalled(info.name))),
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  static Future<void> _run(BuildContext context, Future<Object?> Function() action, String done) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    try {
      await action();
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.cloudStreamFailed(CloudStreamRepository.errorMessage(error)))));
    }
  }

  /// Installs or updates ([done] says which); one that downloads but does not load says so.
  Future<void> _install(BuildContext context, Future<CsInstalledPlugin> Function() action, String Function(String name) done) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    try {
      final installed = await action();
      final error = installed.loadError;
      messenger.showSnackBar(
        SnackBar(content: Text(error == null ? done(info.name) : l10n.cloudStreamInstalledNotLoading(info.name, error))),
      );
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.cloudStreamFailed(CloudStreamRepository.errorMessage(error)))));
    }
  }

  static String _size(int bytes) =>
      bytes >= 1024 * 1024 ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB' : '${(bytes / 1024).ceil()} KB';
}

class _PluginIcon extends StatelessWidget {
  const _PluginIcon({required this.url, required this.name});

  final String? url;
  final String name;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fallback = Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: cs.primaryContainer.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(10)),
      child: Text(
        name.isEmpty ? '?' : name.substring(0, 1).toUpperCase(),
        style: Theme.of(context).textTheme.titleSmall?.copyWith(color: cs.primary, fontWeight: FontWeight.bold),
      ),
    );
    final icon = url;
    if (icon == null || icon.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.network(
        icon,
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
        loadingBuilder: (context, child, progress) => progress == null ? child : fallback,
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color.withValues(alpha: 0.4)),
    ),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color, fontSize: 10, fontWeight: FontWeight.w600),
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.message});

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Scrolls when the tab is shorter than the message (a keyboard up, a phone on its side).
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(LayoutConstants.spacingLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.primary),
            const SizedBox(height: LayoutConstants.spacingMd),
            Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold), textAlign: TextAlign.center),
            const SizedBox(height: LayoutConstants.spacingSm),
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
