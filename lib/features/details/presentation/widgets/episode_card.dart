import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/storage/history_repository.dart';
import 'package:skystream/core/storage/episode_watch_repository.dart';
import 'package:skystream/core/services/download_service.dart';
import 'package:skystream/core/utils/layout_constants.dart';

import '../../../../shared/widgets/thumbnail_error_placeholder.dart';
import '../../../library/presentation/history_provider.dart';
import '../details_controller.dart';
import '../download_launcher.dart';
import '../downloaded_file_provider.dart';
import 'download_progress_dialog.dart';
import 'download_management_dialog.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/focus/app_focus.dart';

class EpisodeCard extends HookConsumerWidget {
  final Episode episode;
  final MultimediaItem parentItem;
  final double? width;

  const EpisodeCard({
    super.key,
    required this.episode,
    required this.parentItem,
    this.width,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final historyRepo = ref.watch(historyRepositoryProvider);
    final historyItem = ref.watch(
      watchHistoryProvider.select(
        (list) => list.whereType<HistoryItem>().firstWhereOrNull(
          (h) => h.item.url == parentItem.url,
        ),
      ),
    );

    final epPos = historyRepo.getEpisodePosition(
      episode.url,
      mainUrl: parentItem.url,
      season: episode.season,
      episode: episode.episode,
    );
    final epDur = historyRepo.getEpisodeDuration(
      episode.url,
      mainUrl: parentItem.url,
      season: episode.season,
      episode: episode.episode,
    );

    ref.watch(episodeWatchRevisionProvider);
    final episodeWatchRepo = ref.watch(episodeWatchRepositoryProvider);

    final double progress = epDur > 0 ? (epPos / epDur).clamp(0.0, 1.0) : 0.0;
    final explicitWatchState = episodeWatchRepo.getExplicitState(
      parentItem.url,
      episode,
    );
    final isWatched = episodeWatchRepo.isWatched(parentItem.url, episode);
    final displayedProgress = isWatched ? 1.0 : progress;

    String? statusBadge;
    if (isWatched) {
      statusBadge = l10n.watched.toUpperCase();
    } else if (progress > 0.02) {
      statusBadge = l10n.watching.toUpperCase();
    }

    if (historyItem != null &&
        statusBadge == null &&
        explicitWatchState != false) {
      final hSeason = historyItem.season ?? 1;
      final hEpisode = historyItem.episode ?? 1;
      final eSeason = episode.season;
      final eEpisode = episode.episode;

      if (eSeason == hSeason && eEpisode == hEpisode) {
        statusBadge = l10n.lastWatched.toUpperCase();
      }
    }

    final activeDownloads = ref.watch(activeDownloadsProvider);
    final isDownloading = activeDownloads.contains(episode.url);
    final detailsState = ref.watch(detailsControllerProvider(parentItem.url));
    final details = detailsState.item;
    final selectionKey = episodeSelectionKey(episode);
    final isSelectionMode = detailsState.selectedEpisodeKeys.isNotEmpty;
    final isSelected = detailsState.selectedEpisodeKeys.contains(selectionKey);

    final progressMap = ref.watch(downloadProgressProvider);
    final downloadProgressData = progressMap[episode.url];
    final downloadProgress = downloadProgressData?.progress ?? 0.0;

    final downloadedFile = ref.watch(downloadedFilesProvider)[episode.url];

    useEffect(() {
      if (!isDownloading) {
        Future.microtask(() {
          if (ref.context.mounted) {
            ref
                .read(downloadedFilesProvider.notifier)
                .checkFile(parentItem, episode: episode);
          }
        });
      }
      return null;
    }, [episode.url, isDownloading]);

    final isFocused = useState(false);
    final downloadFocusNode = useFocusNode(debugLabel: 'ep_download');
    final bodyFocusNode = useFocusNode(debugLabel: 'ep_body');
    // The card-wide InkWell owns a node that is permanently out of traversal.
    // `canRequestFocus: false` alone would not do it: [InkResponse] forces
    // `canRequestFocus` to true whenever the host declares
    // `NavigationMode.directional`, which televisions do, and a focusable node
    // the size of the card would swallow the body's traversal step.
    final cardInkFocusNode = useFocusNode(
      debugLabel: 'ep_card_ink',
      skipTraversal: true,
    );
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final normalCardColor = theme.colorScheme.surfaceContainerLow;
    final watchedCardColor = Color.alphaBlend(
      Colors.black.withValues(
        alpha: theme.brightness == Brightness.dark ? 0.30 : 0.14,
      ),
      normalCardColor,
    );

    void triggerDownload() {
      if (downloadedFile != null) {
        DownloadManagementDialog.show(
          context,
          details ?? parentItem,
          downloadedFile,
          episode: episode,
        );
      } else if (isDownloading) {
        DownloadProgressDialog.show(
          context,
          '${parentItem.title} - ${episode.name}',
          episode.url,
        );
      } else {
        ref
            .read(downloadLauncherProvider)
            .launch(context, parentItem, episodeUrl: episode.url);
      }
    }

    void updateSelection() {
      HapticFeedback.selectionClick();

      ref
          .read(detailsControllerProvider(parentItem.url).notifier)
          .toggleEpisodeSelection(episode);
    }

    void handleEpisodeTap() {
      final selectionActive = ref
          .read(detailsControllerProvider(parentItem.url))
          .selectedEpisodeKeys
          .isNotEmpty;

      if (selectionActive) {
        updateSelection();
        return;
      }

      ref
          .read(detailsControllerProvider(parentItem.url).notifier)
          .handlePlayPress(context, parentItem, specificEpisode: episode);
    }

    final selectKeyDown = useRef(false);
    final longPressTriggered = useRef(false);
    final showFocus = showFocusIndicator(context, isFocused.value);

    return Focus(
      // Passive observer for the card as a whole. `hasFocus` stays true while
      // the download button is the focused child, which keeps the card's
      // border lit and the button's traversal permit open (see
      // [_EpisodeCardAction]).
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) {
        isFocused.value = f;
        if (!f) {
          selectKeyDown.value = false;
          longPressTriggered.value = false;
        }
        if (f) {
          // Center the focused episode in the viewport when reachable.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final ctx = FocusManager.instance.primaryFocus?.context;
            final ro = ctx?.findRenderObject();
            if (ctx != null && ctx.mounted && ro != null) {
              Scrollable.maybeOf(ctx)?.position.ensureVisible(
                ro,
                alignment: 0.5,
                duration: const Duration(milliseconds: 380),
                curve: Curves.fastOutSlowIn,
              );
            }
          });
        }
      },
      child: InkWell(
        onTap: handleEpisodeTap,
        onLongPress: updateSelection,
        // Deliberately NOT a focus stop; the focusable body is the smaller
        // node inside the header row below. This rect encloses the download
        // button, and directional traversal only considers candidates whose
        // centre lies past the focused rect's edge, so from a node the size of
        // the card the button is unreachable in every direction. Tap and
        // long-press still cover the whole card.
        focusNode: cardInkFocusNode,
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: width,
          decoration: BoxDecoration(
            // Selection is a *state* of the episode and stays the accent;
            // focus is where the remote happens to be pointing and is
            // neutral, so the two are still told apart when both are true.
            color: isSelected
                ? primary.withValues(alpha: 0.24)
                : showFocus
                ? AppFocus.rowTint(context, focused: true)
                : isWatched
                ? watchedCardColor
                : normalCardColor,
            borderRadius: BorderRadius.circular(12.0),
            border: Border.all(
              color: showFocus
                  ? AppFocus.ringColor(context)
                  : isSelected
                  ? primary
                  : Theme.of(context).dividerColor.withValues(
                      alpha: Theme.of(context).brightness == Brightness.dark
                          ? 0.1
                          : 0.5,
                    ),
              width: isSelected || showFocus ? AppFocus.ringWidth : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          padding: const EdgeInsets.all(LayoutConstants.spacingSm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // The card's single traversal stop, covering the thumbnail
                  // and the title but NOT the trailing action. Keeping the
                  // action outside this rect is what lets plain directional
                  // traversal walk RIGHT into it and LEFT back out.
                  Expanded(
                    child: Focus(
                      focusNode: bodyFocusNode,
                      onKeyEvent: (node, event) {
                        // Menu key triggers the download immediately.
                        final isMenu =
                            event.logicalKey ==
                                LogicalKeyboardKey.contextMenu ||
                            event.logicalKey == LogicalKeyboardKey.f10;
                        if (event is KeyDownEvent && isMenu) {
                          triggerDownload();
                          return KeyEventResult.handled;
                        }

                        // Select, Enter and Space detect a long press through
                        // KeyRepeatEvent.
                        if (event.logicalKey == LogicalKeyboardKey.select ||
                            event.logicalKey == LogicalKeyboardKey.enter ||
                            event.logicalKey == LogicalKeyboardKey.space) {
                          if (event is KeyDownEvent) {
                            selectKeyDown.value = true;
                            longPressTriggered.value = false;
                            return KeyEventResult.handled;
                          } else if (event is KeyRepeatEvent) {
                            if (selectKeyDown.value &&
                                !longPressTriggered.value) {
                              longPressTriggered.value = true;
                              updateSelection();
                            }
                            return KeyEventResult.handled;
                          } else if (event is KeyUpEvent) {
                            if (selectKeyDown.value &&
                                !longPressTriggered.value) {
                              // Short press plays normally, or toggles when
                              // selecting.
                              handleEpisodeTap();
                            }
                            selectKeyDown.value = false;
                            longPressTriggered.value = false;
                            return KeyEventResult.handled;
                          }
                        }

                        return KeyEventResult.ignored;
                      },
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildThumbnail(
                            context,
                            displayedProgress,
                            statusBadge,
                            isWatched: isWatched,
                            isSelectionMode: isSelectionMode,
                            isSelected: isSelected,
                          ),
                          const SizedBox(width: LayoutConstants.spacingMd),
                          Expanded(
                            child: Text(
                              "${episode.episode}. ${episode.name.toUpperCase()}",
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: isWatched
                                        ? theme.colorScheme.onSurface
                                              .withValues(alpha: 0.65)
                                        : theme.colorScheme.onSurface,
                                  ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: LayoutConstants.spacingXs),
                  if (isSelectionMode)
                    Icon(
                      isSelected
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      color: isSelected
                          ? primary
                          : theme.colorScheme.onSurfaceVariant,
                      size: 30,
                    )
                  else
                    _buildActionButtons(
                      context,
                      ref,
                      downloadedFile,
                      isDownloading,
                      downloadProgress,
                      downloadProgressData,
                      details,
                      downloadFocusNode,
                      cardHasFocus: isFocused.value,
                      onActivate: triggerDownload,
                    ),
                ],
              ),
              if (episode.description != null &&
                  episode.description!.isNotEmpty) ...[
                const SizedBox(height: LayoutConstants.spacingSm),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4.0),
                  child: Text(
                    episode.description!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.8),
                      height: 1.4,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionButtons(
    BuildContext context,
    WidgetRef ref,
    File? downloadedFile,
    bool isDownloading,
    double downloadProgress,
    DownloadProgressData? downloadProgressData,
    MultimediaItem? details,
    FocusNode focusNode, {
    required bool cardHasFocus,
    required VoidCallback onActivate,
  }) {
    final raw = _buildRawActionButton(
      context,
      ref,
      downloadedFile,
      isDownloading,
      downloadProgress,
      downloadProgressData,
      details,
      focusNode,
    );
    if (raw == null) return const SizedBox.shrink();

    // One shape on every platform. Excluding this from focus on wide surfaces
    // strands the download on any device 900 dp or wider, which includes every
    // television (960 dp) and every landscape tablet.
    return _EpisodeCardAction(
      cardHasFocus: cardHasFocus,
      onActivate: onActivate,
      child: raw,
    );
  }

  Widget? _buildRawActionButton(
    BuildContext context,
    WidgetRef ref,
    File? downloadedFile,
    bool isDownloading,
    double downloadProgress,
    DownloadProgressData? downloadProgressData,
    MultimediaItem? details,
    FocusNode focusNode,
  ) {
    if (downloadedFile != null) {
      return IconButton(
        focusNode: focusNode,
        icon: const Icon(
          Icons.download_done_sharp,
          color: Colors.green,
          size: 32,
        ),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        onPressed: () {
          DownloadManagementDialog.show(
            context,
            details ?? parentItem,
            downloadedFile,
            episode: episode,
          );
        },
      );
    } else if (isDownloading) {
      return SizedBox(
        width: 32,
        height: 32,
        child: InkWell(
          focusNode: focusNode,
          onTap: () => DownloadProgressDialog.show(
            context,
            '${parentItem.title} - ${episode.name}',
            episode.url,
          ),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(4.0),
            child: downloadProgressData?.status == TaskStatus.paused
                ? Icon(
                    Icons.pause_rounded,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : Stack(
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(
                        value: downloadProgress > 0 ? downloadProgress : null,
                        strokeWidth: 2,
                      ),
                      Text(
                        "${(downloadProgress * 100).toInt()}%",
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      );
    } else {
      return IconButton(
        focusNode: focusNode,
        icon: Icon(
          Icons.file_download_outlined,
          size: 32,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        onPressed: () {
          ref
              .read(downloadLauncherProvider)
              .launch(context, parentItem, episodeUrl: episode.url);
        },
      );
    }
  }

  Widget _buildThumbnail(
    BuildContext context,
    double progress,
    String? statusBadge, {
    required bool isWatched,
    required bool isSelectionMode,
    required bool isSelected,
  }) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 140,
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: CachedNetworkImage(
                imageUrl: episode.posterUrl ?? '',
                fit: BoxFit.cover,
                errorWidget: (context, url, error) =>
                    const ThumbnailErrorPlaceholder(),
                placeholder: (context, url) => Container(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (isWatched)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.black.withValues(alpha: 0.28),
                ),
              ),
            ),
          ),
        if (progress > 0)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 3,
              backgroundColor: Colors.black26,
              valueColor: AlwaysStoppedAnimation<Color>(
                Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        if (statusBadge != null)
          Positioned(
            top: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary
                    .withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                statusBadge,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        Positioned.fill(
          child: Center(
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                shape: BoxShape.circle,
              ),
              child: Icon(
                isSelectionMode
                    ? isSelected
                          ? Icons.check_rounded
                          : Icons.add_rounded
                    : Icons.play_arrow_rounded,
                color: Colors.white,
                size: 24,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The card's trailing download action: one focus stop, reachable by D-pad,
/// by remote and by keyboard on every platform.
///
/// The card body is the UP/DOWN stop; this button is reached with RIGHT once
/// the card holds focus and LEFT comes back, which is ordinary directional
/// traversal because the body's rect stops short of this button.
///
/// While the card does NOT hold focus its descendants are untraversable, so no
/// other row's icon is ever in the candidate set. DOWN from this button then
/// lands on the next episode rather than that episode's icon, and in the
/// two-column grid a television lays out, LEFT from the right-hand card lands
/// on the left-hand episode rather than on its nearer icon. The button stays
/// focusable throughout; only traversal is gated.
///
/// OK / Enter / Space are answered here rather than left to Flutter's default
/// `SingleActivator -> ActivateIntent`, because those activators take repeats
/// (`includeRepeats` defaults to true) and a remote repeats OK for as long as
/// it is held, which would fire a download on every tick. The wrapper cannot
/// take focus itself, so it sees these events on their way up from the button.
class _EpisodeCardAction extends StatefulWidget {
  final Widget child;

  /// Whether the episode card this action belongs to holds focus, directly or
  /// through this button.
  final bool cardHasFocus;

  final VoidCallback onActivate;

  const _EpisodeCardAction({
    required this.child,
    required this.cardHasFocus,
    required this.onActivate,
  });

  @override
  State<_EpisodeCardAction> createState() => _EpisodeCardActionState();
}

class _EpisodeCardActionState extends State<_EpisodeCardAction> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      descendantsAreTraversable: widget.cardHasFocus,
      onFocusChange: (f) {
        if (f != _focused) setState(() => _focused = f);
      },
      onKeyEvent: (node, event) {
        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.space) {
          // The down edge acts; the repeats and the up edge are swallowed so
          // one held press is one download.
          if (event is KeyDownEvent) widget.onActivate();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (context) {
          final show = showFocusIndicator(context, _focused);
          return AnimatedContainer(
            duration: AppFocus.duration,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: AppFocus.rowTint(context, focused: show),
              border:
                  AppFocus.border(context, focused: show) ??
                  Border.all(
                    color: Colors.transparent,
                    width: AppFocus.ringWidth,
                  ),
            ),
            child: widget.child,
          );
        },
      ),
    );
  }
}
