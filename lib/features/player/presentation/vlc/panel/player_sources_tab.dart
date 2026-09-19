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
import '../../../domain/source_row_status.dart';
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
    this.failed = const <int>{},
    this.played = const <int>{},
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

  /// Sources that were played and would not play, keyed the same way.
  final Set<int> failed;

  /// Sources that have shown a picture, keyed the same way. They read
  /// reachable whatever the probe said: the one playing never says "not
  /// checked" under its own picture.
  final Set<int> played;

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
      // Every row carries a reachability chip - "Not checked" where the probe
      // never looked - so a torrent row's badges run to a second line.
      estimatedRowExtent: 98,
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
        final reachability = sourceReachabilityOf(
          stream,
          probes[index],
          hasPlayed: played.contains(index),
        );
        // Only a failure is worth a second chip here. The row being played
        // already wears `Now playing`, and one being opened is the same row -
        // the startup view is where "Opening" is said.
        final hasFailed = failed.contains(index);

        return PanelRow(
          label: facts.title,
          detail: sourceProvider(stream),
          badges: <String>[
            ?facts.quality,
            ?facts.size,
            if (facts.seeders != null) l10n.playerSeeders(facts.seeders!),
          ],
          selected: selected,
          selectedLabel: l10n.playerNowPlaying,
          status: sourceReachabilityLabel(l10n, reachability),
          statusColor: _reachabilityColour(reachability),
          outcome: hasFailed ? l10n.playerSourceUnplayable : null,
          outcomeColor: hasFailed ? const Color(0xFFE57373) : null,
          autofocus: autofocus && index == anchor,
          icon: Icons.dns_outlined,
          onTap: () => onPick(index),
        );
      },
    );
  }

  /// The reachability chip's colour, worded the way the startup view words it.
  ///
  /// Colour only where it says something the word does not: green for a
  /// source that answered, amber for one the check got no answer from - a
  /// warning, since the probe is wrong about slow hosts. (Red is the failure
  /// chip's, for a source that was played and failed.) Everything else falls
  /// through to the ramp's own badge treatment (`metrics.secondaryText` on
  /// `metrics.divider`), so on a television it is as legible as the badges
  /// beside it. A literal there is what once left "still looking" at the
  /// phone's 45 % white on a set that crushes it, reading as "nothing there".
  static Color? _reachabilityColour(SourceReachability reachability) =>
      switch (reachability) {
        SourceReachability.reachable => const Color(0xFF4CAF50),
        SourceReachability.unreachable => const Color(0xFFFFB74D),
        SourceReachability.checking || SourceReachability.notChecked => null,
      };
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
