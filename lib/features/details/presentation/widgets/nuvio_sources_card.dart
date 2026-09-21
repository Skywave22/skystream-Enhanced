import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/nuvio/data/nuvio_repository.dart';

import 'package:skystream/l10n/generated/app_localizations.dart';

import 'source_section_card.dart';

/// The Nuvio half of a details screen's source discovery, drawn as a peer of
/// the SkyStream [ProviderSearchSection] rather than as a call-to-action
/// button.
///
/// **Why it is a card and not a button.** Both plugin systems answer the same
/// question - "where can I watch this" - so neither gets to be the page's
/// primary action. See [SourceSectionCard].
///
/// **Why it can vanish.** Nuvio has a master switch and per-scraper switches
/// in Settings, and every scraper declares the platforms it runs on.
/// [NuvioState.activeScrapers] is all three of those resolved into one list,
/// so an empty list means a tap could only ever open an empty sheet. The card
/// is removed rather than disabled: a dead control that explains itself is
/// still a dead control taking up the space a live one could use.
class NuvioSourcesCard extends ConsumerWidget {
  const NuvioSourcesCard({
    super.key,
    required this.isMovie,
    required this.onOpen,
    this.compact = false,
  });

  /// Movies go straight to the sources sheet; a series needs a season and an
  /// episode chosen before there is anything to scrape, so it opens the
  /// picker. The label says which, because "Search in Nuvio plugins" opening
  /// an episode list was a small lie the old button told on every series.
  final bool isMovie;

  final VoidCallback onOpen;

  /// Passed through to [SourceSectionCard.compact].
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final scraperCount = ref.watch(
      nuvioRepositoryProvider.select((s) => s.activeScrapers.length),
    );
    if (scraperCount == 0) return const SizedBox.shrink();

    return SourceSectionCard(
      icon: Icons.hub_rounded,
      title: l10n.nuvioPlugins,
      compact: compact,
      badge: SourceSectionBadge(label: l10n.nuvioScraperCount(scraperCount)),
      child: Padding(
        padding: compact
            ? EdgeInsets.zero
            : const EdgeInsets.symmetric(horizontal: SourceSectionCard.gutter),
        child: SourceSectionAction(
          label: isMovie ? l10n.nuvioSearchForStreams : l10n.nuvioChooseEpisode,
          icon: isMovie ? Icons.search_rounded : Icons.playlist_play_rounded,
          onTap: onOpen,
          // Full bleed on a phone, where a thumb wants the whole width and
          // there is nothing to share the row with. On a desktop the card sits
          // in a hero column that can run well past a thousand points, and a
          // button stretched across all of it reads as a banner rather than a
          // control - so there it is capped. A cap rather than a fixed width,
          // so a narrow desktop window shrinks it instead of overflowing.
          maxWidth: compact ? kSourceActionDesktopWidth : null,
        ),
      ),
    );
  }
}
