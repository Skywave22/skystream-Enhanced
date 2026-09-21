import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:skystream/l10n/generated/app_localizations.dart';

import '../../../../core/addons/data/addon_repository.dart';
import '../../../../core/addons/data/addon_stream_service.dart';
import '../../../details/presentation/widgets/source_section_card.dart';

/// Stremio's source discovery on an add-on details screen, drawn the same way
/// the Nuvio card is drawn on a TMDB one.
///
/// **Why it is a card and not a button.** It used to be a saturated
/// [FilledButton] reading "Play from add-ons", which made it the page's
/// primary action and promised playback for a tap that opens a list of links.
/// Every other source-discovery block in the app is a [SourceSectionCard]; this
/// is that block for Stremio.
///
/// **Why it can vanish.** Only an add-on that declares the `stream` resource
/// can answer this - catalog-only add-ons (Trakt lists, Streaming Catalogs)
/// are never asked, and [AddonStreamService.streamProvidersOf] is the single
/// place that knows it. With none installed the tap could only ever open a
/// sheet that says so, which is worse than no card.
class StremioSourcesCard extends ConsumerWidget {
  const StremioSourcesCard({
    super.key,
    required this.onOpen,
    this.episode,
    this.compact = false,
  });

  /// The season and episode this card resolves, or null for a movie.
  ///
  /// A series' card is a shortcut to one episode - the first of the selected
  /// season - and the label names it, because the episode list further down
  /// the page is how any other episode is reached. "Play S1 E1" already said
  /// as much; it just said "play" for something that opens a list.
  final ({int season, int episode})? episode;

  final VoidCallback onOpen;

  /// Passed through to [SourceSectionCard.compact].
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final addonCount = ref.watch(
      addonRepositoryProvider.select(
        (s) => AddonStreamService.streamProvidersOf(s.enabled).length,
      ),
    );
    if (addonCount == 0) return const SizedBox.shrink();

    final target = episode;
    return SourceSectionCard(
      icon: Icons.extension_rounded,
      title: l10n.stremioAddons,
      compact: compact,
      badge: SourceSectionBadge(label: l10n.stremioAddonCount(addonCount)),
      child: Padding(
        padding: compact
            ? EdgeInsets.zero
            : const EdgeInsets.symmetric(horizontal: SourceSectionCard.gutter),
        child: SourceSectionAction(
          label: target == null
              ? l10n.stremioSearchAddons
              // (season, episode) - the order gen-l10n emits from the ARB
              // placeholders. Both are ints, so getting it backwards compiles
              // cleanly and renders the numbers swapped.
              : l10n.stremioSearchAddonsForEpisode(
                  target.season,
                  target.episode,
                ),
          icon: Icons.search_rounded,
          onTap: onOpen,
          // Full bleed on a phone; capped on a desktop, where the card sits in
          // a hero column that can run past a thousand points and a button
          // stretched across all of it reads as a banner.
          maxWidth: compact ? kSourceActionDesktopWidth : null,
        ),
      ),
    );
  }
}
