import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../l10n/generated/app_localizations.dart';
import '../providers/update_provider.dart';
import '../router/app_router.dart';
import '../storage/storage_service.dart';
import '../data/models/github_release.dart';

class UpdateDialog extends ConsumerWidget {
  final GithubRelease release;

  const UpdateDialog({super.key, required this.release});

  static Future<void> show(BuildContext context, GithubRelease release) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => UpdateDialog(release: release),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final updateState = ref.watch(updateControllerProvider);
    final l10n = AppLocalizations.of(context)!;

    return PopScope(
      canPop: updateState is! UpdateDownloading,
      // Fires for every way out of this dialog - the Later button below, the
      // Android back gesture, Escape, a D-pad Back on a television - so the
      // record of "asked and answered" cannot be sidestepped by choosing a
      // different exit. A failed download is the one exception: that release
      // was accepted, not declined, and the user has to be offered it again.
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop || updateState is UpdateError) return;
        ref.read(storageServiceProvider).setDeclinedUpdateTag(release.tagName);
      },
      child: AlertDialog(
        title: Text(l10n.updateAvailableTag(release.tagName)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (updateState is UpdateDownloading) ...[
              Text(l10n.downloadingUpdate),
              const SizedBox(height: 10),
              LinearProgressIndicator(value: updateState.progress),
              const SizedBox(height: 10),
              Text('${(updateState.progress * 100).toStringAsFixed(0)}%'),
            ] else if (updateState is UpdateError) ...[
              Text(
                l10n.errorPrefix(updateState.message),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ] else ...[
              // Truncate body if too long
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: SingleChildScrollView(child: Text(release.body)),
              ),
            ],
          ],
        ),
        actions: [
          if (updateState is! UpdateDownloading)
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.later),
            ),
          if (updateState is! UpdateDownloading)
            FilledButton(
              autofocus: true,
              onPressed: () {
                ref
                    .read(updateControllerProvider.notifier)
                    .downloadAndInstall(release);
              },
              child: Text(l10n.updateNow),
            ),
        ],
      ),
    );
  }
}

/// Decides *when* an available release may be put in front of the user, and
/// puts it there.
///
/// Mounted in `MaterialApp.router`'s builder next to the global toast layer,
/// because it answers the same two questions that layer does: is the player on
/// top right now, and has the user already been told this once.
///
/// Two rules, both earned:
///
///  * **Never over the player.** The check fires five seconds after launch, so
///    a user who taps Continue Watching gets a modal dropped on their film -
///    `barrierDismissible: false`, and on a television it takes the D-pad with
///    it. The offer is held instead and made when the player is popped, which
///    is a moment the user is choosing what to do next anyway.
///  * **Once per release.** A dismissal is remembered against the release tag
///    (`StorageService.getDeclinedUpdateTag`), so "Later" means later and not
///    "again in four hours when you next open the app".
///
/// Renders [child] untouched; it is a behaviour, not a decoration.
class UpdatePromptHost extends ConsumerStatefulWidget {
  const UpdatePromptHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<UpdatePromptHost> createState() => _UpdatePromptHostState();
}

class _UpdatePromptHostState extends ConsumerState<UpdatePromptHost> {
  /// An offer that arrived while the player was on top, waiting for it to go.
  GithubRelease? _deferred;

  /// True between `showDialog` and its dismissal, so a second
  /// [UpdateAvailable] - a re-check, a hot reload - cannot stack a second
  /// dialog on the first.
  bool _showing = false;

  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _router = ref.read(appRouterProvider);
    _router.routerDelegate.addListener(_onRouteChanged);
    // Manual rather than a `ref.listen` in build: the offer is a one-shot
    // side effect, and build runs for reasons that have nothing to do with it.
    ref.listenManual<UpdateState>(updateControllerProvider, (previous, next) {
      if (next is UpdateAvailable) _offer(next.release);
    });
  }

  @override
  void dispose() {
    _router.routerDelegate.removeListener(_onRouteChanged);
    super.dispose();
  }

  void _onRouteChanged() {
    final release = _deferred;
    if (release == null || playerRouteIsOnTop(_router)) return;
    _deferred = null;
    // The delegate notifies from inside the navigation that changed it, and
    // pushing a dialog route from there throws. Hand it to the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _offer(release);
    });
  }

  void _offer(GithubRelease release) {
    if (!mounted || _showing) return;

    if (playerRouteIsOnTop(_router)) {
      _deferred = release;
      return;
    }

    if (ref.read(storageServiceProvider).getDeclinedUpdateTag() ==
        release.tagName) {
      return;
    }

    // The *root* navigator: the dialog has to sit above the shell, and the
    // player route is a sibling of it rather than a child.
    final navContext = _router.routerDelegate.navigatorKey.currentContext;
    if (navContext == null || !navContext.mounted) return;

    _showing = true;
    UpdateDialog.show(navContext, release).whenComplete(() {
      _showing = false;
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
