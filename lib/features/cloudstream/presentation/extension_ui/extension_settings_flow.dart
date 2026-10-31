import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/cloudstream/cloudstream_engine.dart';
import '../../../../core/cloudstream/cloudstream_models.dart';
import '../../../../core/cloudstream/cloudstream_repository.dart';
import '../../../../core/cloudstream/extension_ui/extension_ui_session.dart';
import '../../../../core/providers/device_info_provider.dart';
import '../../../../l10n/generated/app_localizations.dart';
import 'extension_full_screen.dart';
import 'extension_sheet.dart';

/// Extensions whose screen is opening or open, per app (its root navigator): a second tap on Settings
/// (a double tap) opens nothing more.
final _showing = Expando<Set<String>>();

/// Opens [plugin]'s own settings screen in SkyStream's sheet. Once it closes, the extension reloads, so
/// its changes apply, if the person changed anything there or it asked to restart the app.
Future<void> openExtensionSettings(BuildContext context, WidgetRef ref, CsInstalledPlugin plugin) async {
  final showing = _showing[Navigator.of(context, rootNavigator: true)] ??= <String>{};
  if (!showing.add(plugin.filePath)) return;
  try {
    await _openExtensionSettings(context, ref, plugin);
  } finally {
    showing.remove(plugin.filePath);
  }
}

Future<void> _openExtensionSettings(BuildContext context, WidgetRef ref, CsInstalledPlugin plugin) async {
  final l10n = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.of(context);
  final host = ref.read(cloudStreamEngineHostProvider);
  final tv = ref.read(deviceProfileProvider).value?.isTv ?? false;
  final ExtensionUiSession session;
  try {
    session = await ExtensionUiSession.open(HostUiApi(host, pluginUrl: plugin.info.url), plugin.filePath);
  } catch (error) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(l10n.cloudStreamSettingsFailed(plugin.info.name, CloudStreamRepository.errorMessage(error))),
      ),
    );
    return;
  }
  if (!context.mounted) {
    unawaited(session.close(force: true));
    return;
  }
  await showExtensionScreen(context, session: session, name: plugin.info.name, tv: tv);
  if (!session.closed) {
    // The sheet went without the screen ending (the app navigated away under it): end the screen, so
    // the extension isn't reloaded with its windows still open.
    await session.close(force: true);
    await session.done.timeout(const Duration(seconds: 3), onTimeout: () {});
  }
  final changed = session.actionsSent > 0 || session.restartRequested;
  final crash = session.closedReason == 'error' ? session.closedError ?? '' : null;
  session.dispose();
  if (crash != null) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.cloudStreamSettingsStopped(plugin.info.name, crash))));
  }
  // Reload the extension only when something actually changed: an extension that keeps its
  // settings in memory asks for a restart to apply them, and the app does not restart, so it
  // only applies them when its code runs again. When nothing changed there is nothing to apply.
  if (changed) {
    try {
      await ref.read(cloudStreamRepositoryProvider.notifier).applySettings(plugin);
      messenger.showSnackBar(SnackBar(content: Text(l10n.cloudStreamSettingsApplied(plugin.info.name))));
    } catch (error) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(l10n.cloudStreamSettingsApplyFailed(plugin.info.name, CloudStreamRepository.errorMessage(error))),
      ),
    );
  }
  }
}

/// Opens [plugin]'s kept pop-ups (its Support button) in SkyStream's sheet, live: their buttons work, and
/// closing one dismisses it. Nothing reloads after: they're the extension's messages, not its settings.
Future<void> openExtensionPopups(BuildContext context, WidgetRef ref, CsInstalledPlugin plugin) async {
  final showing = _showing[Navigator.of(context, rootNavigator: true)] ??= <String>{};
  if (!showing.add(plugin.filePath)) return;
  try {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final host = ref.read(cloudStreamEngineHostProvider);
    final tv = ref.read(deviceProfileProvider).value?.isTv ?? false;
    final ExtensionUiSession session;
    try {
      session = await ExtensionUiSession.openPopups(HostUiApi(host, pluginUrl: plugin.info.url), plugin.filePath);
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.cloudStreamSupportFailed(plugin.info.name, CloudStreamRepository.errorMessage(error))),
        ),
      );
      return;
    }
    if (!context.mounted) {
      unawaited(session.close(force: true));
      return;
    }
    await showExtensionWindows(context, session: session, name: plugin.info.name, tv: tv);
  } finally {
    showing.remove(plugin.filePath);
  }
}

/// Shows [session] until the engine ends it: in SkyStream's sheet, or full screen while its windows ask for it (Phase
/// 7c's §2), moving between the two as its windows change. Returns early when the app navigated away from under it:
/// the caller then ends the screen.
Future<void> showExtensionScreen(
  BuildContext context, {
  required ExtensionUiSession session,
  required String name,
  required bool tv,
  FullScreenDevice? device,
}) async {
  bool fullScreenFirst() => session.windows.isNotEmpty && session.windows.first.fullScreen;
  await session.firstWindows();
  while (!session.closed) {
    if (!context.mounted) return;
    if (fullScreenFirst()) {
      await showExtensionFullScreen(context, session: session, title: name, device: device);
      // Gone with a window still asking for the whole screen: the app navigated away under it.
      if (!session.closed && fullScreenIndex(session.windows) != null) return;
    } else {
      await showExtensionSheet(context, session: session, title: name, tv: tv, device: device);
      // Gone without handing over to the full-screen view: the app navigated away under it.
      if (!session.closed && !fullScreenFirst()) return;
    }
  }
}

/// Shows [session] in SkyStream's sheet or full screen, titled [name], until the engine ends it: a screen with nothing
/// to apply after (kept pop-ups, or a window the person waits on).
Future<void> showExtensionWindows(
  BuildContext context, {
  required ExtensionUiSession session,
  required String name,
  required bool tv,
}) async {
  await showExtensionScreen(context, session: session, name: name, tv: tv);
  if (!session.closed) {
    // The sheet went without the screen ending (the app navigated away under it): end the screen.
    await session.close(force: true);
    await session.done.timeout(const Duration(seconds: 3), onTimeout: () {});
  }
  session.dispose();
}
