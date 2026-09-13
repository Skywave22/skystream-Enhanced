import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/providers/device_info_provider.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/utils/image_fallbacks.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../../core/utils/responsive_breakpoints.dart';
import '../../../../shared/widgets/multimedia_card.dart';
import '../library_provider.dart';

import '../library_state.dart';
import '../../../../shared/widgets/loading_indicator.dart';

/// Hands the D-pad highlight back to the cell a viewer opened, when they come
/// back to a lazily built collection — a grid, or a rail.
///
/// WHY IT IS NEEDED AT ALL. The framework already remembers the focused child
/// of a route's focus scope, so in the simple case popping a details page puts
/// the highlight back by itself. It stops working the moment the collection
/// rebuilds its cells while the viewer is away, which the bookmarks grid does
/// on the most ordinary journey there is: bookmark toggled on a details page →
/// `Library.refresh()` → a list one item shorter → every cell after the change
/// now sits at a lower index → `SliverChildBuilderDelegate` sees a different
/// [ValueKey] at that index → the old tile element is torn down → its
/// [FocusNode] is disposed → the scope's memory of the focused child dies with
/// it → the next D-pad press starts traversal from the top-left card. That is
/// the "highlight snapped to the first poster" a viewer sees halfway down a
/// long grid.
///
/// WHY THE NODE LIVES HERE AND NOT IN THE CELL. This object is owned by the
/// collection's [State], so it outlives any number of tile rebuilds — which is
/// the whole point, since a tile rebuild is what breaks the framework's own
/// restoration. A per-tile node (`useFocusNode`, or a node created in the
/// tile's `initState`) is disposed by the very rebuild it would have to
/// survive, and calling `requestFocus` on it afterwards throws.
///
/// ONE node, not one per cell: only one cell is ever the return target, and a
/// map of nodes keyed by item would have to be pruned every time the list
/// changes — pruning being exactly the disposal hazard this design avoids.
///
/// HOW TO USE IT, in three lines:
/// ```dart
/// late final _focusReturn = GridFocusReturn(onTargetChanged: () => setState(() {}));
/// // ... in the item builder:
/// Card(focusNode: _focusReturn.nodeFor(item.id), onTap: () => _open(item));
/// // ... after the push future completes, on a focus-driven device only:
/// _focusReturn.restoreTo(item.id);
/// ```
/// The cell must forward the node to whatever draws its focus ring
/// (`CardsWrapper` via `MultimediaCard.focusNode` here) and must not dispose
/// it: the node belongs to this object, which disposes it with the collection.
///
/// This class is deliberately free of anything specific to bookmarks. It lives
/// in this file only because this is the first grid to adopt it; the moment a
/// second one does, lift it verbatim into `lib/shared/widgets/`.
class GridFocusReturn {
  GridFocusReturn({required VoidCallback onTargetChanged, String? debugLabel})
    : _onTargetChanged = onTargetChanged,
      _node = FocusNode(debugLabel: debugLabel ?? 'GridFocusReturn');

  /// Rebuilds the collection so the target cell picks the node up. Normally
  /// `() => setState(() {})`.
  final VoidCallback _onTargetChanged;

  final FocusNode _node;

  /// Identity of the cell the highlight is owed to — an item id, a URL, any
  /// value that is stable across a rebuild. Never an index: an index is the
  /// one thing that moves when the list changes.
  Object? _target;

  bool _disposed = false;

  /// The node the cell identified by [id] should install, or null for every
  /// other cell.
  FocusNode? nodeFor(Object id) => _target == id ? _node : null;

  /// Aims at [id] and puts the highlight back on it after the next frame.
  ///
  /// Call it when the pushed route has been popped. It is a safe no-op in all
  /// three ways the target can fail to be there:
  ///  * the cell was scrolled out of the build while the viewer was away — the
  ///    node was never attached, so [FocusNode.context] is null;
  ///  * the item was removed while the viewer was away (the bookmark deleted
  ///    on the details page) — no cell claims the node, same null context;
  ///  * the tile was disposed — its element is unmounted, so the context that
  ///    [FocusAttachment.detach] leaves behind reports `mounted == false`.
  ///
  /// The null check is not decoration. `FocusNode.requestFocus` on a node with
  /// no parent does not fail loudly; it sets an internal
  /// `_requestFocusWhenReparented` flag and steals the highlight later, the
  /// instant that cell happens to be built again — which on a grid is when the
  /// viewer scrolls past it, long after they stopped caring.
  void restoreTo(Object id) {
    if (_disposed) return;
    _target = id;
    _onTargetChanged();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      final BuildContext? cell = _node.context;
      if (cell == null || !cell.mounted) return;
      if (!_node.canRequestFocus) return;
      _node.requestFocus();
    });
  }

  /// Call from the collection's `dispose`. The [_disposed] latch matters as
  /// much as the disposal: the viewer can leave the whole screen while a
  /// details page is open, and the pending post-frame callback would otherwise
  /// touch a dead node.
  void dispose() {
    _disposed = true;
    _node.dispose();
  }
}

class BookmarksTab extends ConsumerStatefulWidget {
  const BookmarksTab({super.key});

  @override
  ConsumerState<BookmarksTab> createState() => _BookmarksTabState();
}

class _BookmarksTabState extends ConsumerState<BookmarksTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late final GridFocusReturn _focusReturn = GridFocusReturn(
    onTargetChanged: () {
      if (mounted) setState(() {});
    },
    debugLabel: 'bookmarks grid focus return',
  );

  @override
  void dispose() {
    _focusReturn.dispose();
    super.dispose();
  }

  /// Whether this device draws a focus highlight worth putting back.
  ///
  /// The same question, asked the same way, as the gesture rows in
  /// `player_settings_screen.dart`: a hardware fact, read from the hardware.
  /// The mobile operating systems minus the leanback boxes and Apple TVs that
  /// run them without a touchscreen. `DeviceProfile.isTv` is the single
  /// authority for "this is a television"; window shape never reaches this
  /// decision, so a phone in landscape is still a phone.
  ///
  /// On a touchscreen there is no highlight on screen to restore — nothing was
  /// visibly focused when the viewer tapped the poster — so restoring one
  /// would paint a ring the viewer never asked for and hand the next hardware
  /// key press a different starting point.
  bool get _restoresFocus {
    final platform = Theme.of(context).platform;
    final profile = ref.read(deviceProfileProvider).asData?.value;
    final isTouchDevice =
        (platform == TargetPlatform.android ||
            platform == TargetPlatform.iOS) &&
        profile?.isTv != true;
    return !isTouchDevice;
  }

  /// Opens a bookmark and, on the way back, puts the highlight where the
  /// viewer left it.
  ///
  /// The await is the whole mechanism: `push` completes when the details page
  /// is popped, which is the one moment we know the viewer is looking at this
  /// grid again.
  Future<void> _openDetails(MultimediaItem item) async {
    await DetailsRoute(
      $extra: DetailsRouteExtra(item: item),
    ).push<void>(context);
    if (!mounted) return;
    if (!_restoresFocus) return;
    _focusReturn.restoreTo(item.url);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final libraryState = ref.watch(libraryProvider);
    final isLarge = context.isTabletOrLarger;
    final double totalHeight = isLarge ? 180.0 : 150.0;

    return switch (libraryState) {
      LibraryLoading() => const Center(child: AppLoadingIndicator()),
      LibraryError(message: final msg) => Center(child: Text(msg)),
      LibraryEmpty() => _buildEmpty(context),
      LibrarySuccess(items: final items) => GridView.builder(
        padding: const EdgeInsets.fromLTRB(
          LayoutConstants.spacingMd,
          LayoutConstants.spacingMd,
          LayoutConstants.spacingMd,
          100,
        ),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: totalHeight,
          childAspectRatio: 2 / 3.4,
          crossAxisSpacing: LayoutConstants.spacingMd,
          mainAxisSpacing: LayoutConstants.spacingMd,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return MultimediaCard(
            key: ValueKey(item.url),
            // Keyed by URL, not by index: the index is what moves when a
            // bookmark is added or removed while the viewer is away.
            focusNode: _focusReturn.nodeFor(item.url),
            imageUrl:
                AppImageFallbacks.poster(item.posterUrl, label: item.title) ??
                '',
            title: item.title,
            heroTag: 'lib_bookmark_${item.url}_$index',
            onTap: () => _openDetails(item),
          );
        },
      ),
    };
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.bookmark_outline_rounded,
            size: 64,
            color: Theme.of(context).dividerColor,
          ),
          const SizedBox(height: 16),
          Text(
            AppLocalizations.of(context)!.libraryEmpty,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}
