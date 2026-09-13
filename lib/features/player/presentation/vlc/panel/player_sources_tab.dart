/// The Sources tab.
///
/// What the bottom sheet it replaces showed was `displaySource` in a bare
/// [ListTile] — one unlocalised string per row, no quality, no size, no marker
/// for the source actually playing. Everything added here was already in the
/// app and going unread: [qualityBadgeLabel] had no call sites anywhere,
/// `ResolvedPlayback.qualityFilteredFallback` was computed and never shown, and
/// the probe outcomes the resolving screen displays vanished the moment
/// playback started.
library;

import 'player_anchored_list.dart';
import 'package:flutter/material.dart';

import '../../../../../core/domain/entity/multimedia_item.dart';
import '../../../../../l10n/generated/app_localizations.dart';
import '../../../domain/stream_resolver.dart';
import 'player_panel_labels.dart';
import 'player_panel_metrics.dart';
import 'player_panel_row.dart';

class PlayerSourcesTab extends StatelessWidget {
  const PlayerSourcesTab({
    required this.sources,
    required this.currentIndex,
    required this.onPick,
    this.probes = const <int, ProbeOutcome>{},
    this.qualityFilteredFallback = false,
    this.anchorIndex,
    this.autofocus = false,
    super.key,
  });

  final List<StreamResult> sources;

  /// Index into [sources] of the stream the engine is playing. Drives the tick
  /// and the `Now playing` badge, and follows live data.
  final int currentIndex;

  /// Index into [sources] of the row the list opens on and, with [autofocus],
  /// focuses. Defaults to [currentIndex]; the panel passes the value it saw at
  /// open so a failover after that ticks a new row without scrolling the list.
  final int? anchorIndex;

  /// Live health of each candidate, keyed the same way [sources] is indexed.
  final Map<int, ProbeOutcome> probes;

  /// Whether the quality filter matched nothing and was dropped, which is why
  /// sources below the viewer's preference are in this list.
  final bool qualityFilteredFallback;

  final ValueChanged<int> onPick;

  /// Whether the current source's row should take focus as the panel opens.
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (sources.isEmpty) return PanelEmpty(text: l10n.playerNoStreamsFound);

    // Where the list opens and focus lands. The row playing now, or the first
    // one when nothing is playing yet - which is the failed stage, and the one
    // place a remote most needs somewhere to land.
    final wanted = anchorIndex ?? currentIndex;
    final anchor = wanted >= 0 && wanted < sources.length ? wanted : 0;

    return PanelAnchoredList(
      anchorIndex: qualityFilteredFallback ? anchor + 1 : anchor,
      estimatedRowExtent: 84,
      autofocus: autofocus,
      itemCount: sources.length + (qualityFilteredFallback ? 1 : 0),
      itemBuilder: (context, position) {
        // The banner rides in the list rather than above it so it scrolls away
        // with the rows it is describing.
        if (qualityFilteredFallback && position == 0) {
          return _FallbackBanner(text: l10n.playerQualityFilterDropped);
        }
        final index = qualityFilteredFallback ? position - 1 : position;
        final stream = sources[index];
        final facts = sourceFactsOf(stream);
        final selected = index == currentIndex;
        final (status, statusColour) = _probeState(l10n, probes[index]);

        return PanelRow(
          label: facts.title,
          detail: stream.providerName.trim().isEmpty
              ? null
              : stream.providerName,
          badges: <String>[
            ?facts.quality,
            ?facts.size,
            if (facts.seeders != null) l10n.playerSeeders(facts.seeders!),
          ],
          selected: selected,
          selectedLabel: l10n.playerNowPlaying,
          status: status,
          statusColor: statusColour,
          autofocus: autofocus && index == anchor,
          icon: Icons.dns_outlined,
          onTap: () => onPick(index),
        );
      },
    );
  }

  /// The probe result as a chip. Only the states the viewer can act on: a
  /// candidate still being tried, one that answered, one that did not.
  (String?, Color?) _probeState(AppLocalizations l10n, ProbeOutcome? outcome) {
    return switch (outcome) {
      null => (null, null),
      // No colour: the chip falls through to the ramp's own badge treatment
      // (`metrics.secondaryText` on `metrics.divider`), so on a television it
      // is as legible as the two beside it. A colour here would have to be a
      // literal, and a literal is what left this one chip at the phone's 45 %
      // white on a set that crushes it - "still looking" reading as "nothing
      // there". Green and red stay: those two say something the word does
      // not.
      ProbeOutcome.trying => (l10n.trying, null),
      ProbeOutcome.healthy => (
        l10n.playerSourceReachable,
        const Color(0xFF4CAF50),
      ),
      ProbeOutcome.unhealthy => (l10n.failed, const Color(0xFFE57373)),
    };
  }
}

/// Says why sources the viewer's quality preference excludes are in the list.
///
/// Without it the filter looks broken: somebody who asked for 1080p and is
/// handed a 480p list has no way to know the title simply had nothing better.
class _FallbackBanner extends StatelessWidget {
  const _FallbackBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    // The banner is prose, and it sits directly above the row a remote lands
    // on, so it is the first thing a viewer's eye goes to on the tab they read
    // longest. It was the one panel descendant still drawn from literals -
    // 11 sp is 22 physical pixels on a 1080p set at dp 2.0.
    final metrics = PlayerPanelMetrics.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 10, 10, 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0x1FFFC107),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0x66FFC107)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.filter_alt_off_rounded,
            size: metrics.bannerIconSize,
            color: const Color(0xFFFFC107),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: const Color(0xFFFFE082),
                fontSize: metrics.bannerTextSize,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
