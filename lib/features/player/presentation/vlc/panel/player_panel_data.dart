/// What the panel shows, as one value the screen publishes.
///
/// The panel used to be handed nine loose arguments at open, some by value and
/// one - the probe map - by reference, so it was neither a snapshot nor live:
/// a failover after open left the tick on the wrong row, while a re-resolve
/// that cleared the screen's map emptied the chips under the viewer's thumb.
/// Now the screen publishes a [PanelData] through a `ValueListenable` every
/// time one of these facts changes, and the panel rebuilds from it. The panel
/// reads the value once at open for the row it anchors and focuses on, and
/// from then on live data moves only the tick, the chips and the badges.
///
/// Callbacks, `isTv`, `focusOnOpen`, the initial tab and the engine-owned track
/// lists stay out of it: none of them is a fact about the media that changes
/// while the panel is up.
///
/// Watch progress is the other thing deliberately outside [PanelData]: it
/// arrives as an [EpisodeProgressLookup], a function asked one episode at a
/// time. See that typedef for why a map would be the wrong shape.
library;

import 'package:flutter/foundation.dart';

import '../../../../../core/domain/entity/multimedia_item.dart';
import '../../../domain/stream_resolver.dart';
import '../../../domain/subtitle_search_target.dart';
import '../torrent_file_sheet.dart';
import 'player_panel.dart';

/// How far through one episode the viewer got, and whether it counts as seen.
///
/// [watched] is not `fraction >= something`: it is the repository's own answer,
/// which honours an explicit mark from the details screen before it looks at a
/// position at all. So an episode marked watched by hand reads as watched here
/// even at fraction 0, and a 97 %-watched episode reads as watched rather than
/// being painted with a near-full bar.
@immutable
class EpisodeProgress {
  const EpisodeProgress({this.fraction = 0, this.watched = false});

  /// Nothing known. What every row shows when no lookup was supplied, and what
  /// the row that is playing right now shows whatever the store says.
  static const EpisodeProgress none = EpisodeProgress();

  /// Position over duration, 0..1. Zero when nothing is stored for it.
  final double fraction;

  /// Seen: marked by hand, or past the repository's own completion threshold.
  final bool watched;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EpisodeProgress &&
          fraction == other.fraction &&
          watched == other.watched);

  @override
  int get hashCode => Object.hash(fraction, watched);

  @override
  String toString() =>
      'EpisodeProgress(fraction: $fraction, watched: $watched)';
}

/// What the Episodes tab asks, one row at a time, as that row is built.
///
/// A FUNCTION, NOT DATA, and not a field on [PanelData], for three reasons:
///
///   * A closure has no `==`. Putting one on [PanelData] would make every
///     published value unequal to the last, and [PanelData]'s equality is the
///     only thing keeping the panel still under a 3 s torrent poll.
///   * A 200-entry map would have to be built and `mapEquals`-compared on
///     every one of the screen's publishes, and each entry costs a SHA-256
///     (`EpisodeWatchRepository._episodeKey`) plus two history reads.
///   * Progress could not be detected through the existing `episodes` field
///     even if it were stored on [Episode]: that list compares with
///     `listEquals`, and `Episode.==` is `(url, season, episode)` only.
///
/// Asked lazily, the bill is the rows a `ListView.builder` actually builds -
/// roughly the visible ones plus the cache extent - however long the season is.
/// The panel cannot read providers; the screen builds the closure and passes it
/// in.
typedef EpisodeProgressLookup = EpisodeProgress Function(Episode episode);

@immutable
class PanelData {
  const PanelData({
    this.sources = const <StreamResult>[],
    this.currentSourceIndex = -1,
    this.probes = const <int, ProbeOutcome>{},
    this.failedSources = const <int>{},
    this.playedSources = const <int>{},
    this.qualityFilteredFallback = false,
    this.episodes = const <Episode>[],
    this.currentEpisode,
    this.files = const <TorrentFile>[],
    this.currentFileIndex,
    this.subtitleTarget,
  });

  /// Nothing resolved yet. What the screen publishes before its first resolve
  /// and what a panel opened at that moment sees.
  static const PanelData empty = PanelData();

  /// The candidate list, in resolution order. Never emptied mid re-resolve:
  /// the screen keeps the previous list until the new one exists, so an open
  /// Sources tab keeps its rows - and its focused row - under the viewer.
  final List<StreamResult> sources;

  /// Index into [sources] of the stream the engine is playing, or -1 when
  /// nothing is: the failed stage, or a re-resolve in progress.
  final int currentSourceIndex;

  /// The health probe's findings, keyed the way [sources] is indexed. A copy
  /// the screen cannot mutate underneath the panel; see the library doc.
  final Map<int, ProbeOutcome> probes;

  /// Sources opened this resolve that would not play, or stopped, keyed the
  /// way [sources] is indexed. What playing a source found outranks what the
  /// probe found, so a row here reads as failed whatever [probes] says.
  final Set<int> failedSources;

  /// Sources that have shown a picture this resolve, keyed the same way. A
  /// picture is proof of reach no probe can beat, so these read reachable.
  final Set<int> playedSources;

  /// Whether the quality filter matched nothing and was dropped.
  final bool qualityFilteredFallback;

  /// The list the next arrow walks, filtered the same way.
  final List<Episode> episodes;
  final Episode? currentEpisode;

  /// Playable files inside the active torrent, in the torrent's order.
  final List<TorrentFile> files;

  /// The server's id of the file being streamed - an id like
  /// [TorrentFile.index], not a position in [files].
  final int? currentFileIndex;

  /// What an online subtitle search from this panel is about. Null before the
  /// screen knows what is playing.
  final SubtitleSearchTarget? subtitleTarget;

  /// Which tabs the panel shows for this data. The strip and the bottom-bar
  /// buttons both read it, so a button can never open a tab that is not there.
  Set<PlayerPanelTab> get tabs => availablePanelTabs(
    sourceCount: sources.length,
    episodeCount: episodes.length,
    fileCount: files.length,
  );

  PanelData copyWith({
    List<StreamResult>? sources,
    int? currentSourceIndex,
    Map<int, ProbeOutcome>? probes,
    Set<int>? failedSources,
    Set<int>? playedSources,
    bool? qualityFilteredFallback,
    List<Episode>? episodes,
    Episode? currentEpisode,
    bool clearCurrentEpisode = false,
    List<TorrentFile>? files,
    int? currentFileIndex,
    bool clearCurrentFileIndex = false,
    SubtitleSearchTarget? subtitleTarget,
    bool clearSubtitleTarget = false,
  }) {
    return PanelData(
      sources: sources ?? this.sources,
      currentSourceIndex: currentSourceIndex ?? this.currentSourceIndex,
      probes: probes ?? this.probes,
      failedSources: failedSources ?? this.failedSources,
      playedSources: playedSources ?? this.playedSources,
      qualityFilteredFallback:
          qualityFilteredFallback ?? this.qualityFilteredFallback,
      episodes: episodes ?? this.episodes,
      currentEpisode: clearCurrentEpisode
          ? null
          : currentEpisode ?? this.currentEpisode,
      files: files ?? this.files,
      currentFileIndex: clearCurrentFileIndex
          ? null
          : currentFileIndex ?? this.currentFileIndex,
      subtitleTarget: clearSubtitleTarget
          ? null
          : subtitleTarget ?? this.subtitleTarget,
    );
  }

  /// Equality is what keeps the panel still: a `ValueNotifier` drops a value
  /// equal to the one it holds, so a torrent poll that found the same files
  /// or a probe that changed nothing never reaches the panel at all.
  ///
  /// Sources compare by identity - [StreamResult] has no `==` and the screen
  /// holds one list per resolve, so identity is the honest test. Episodes and
  /// files compare element-wise because both lists are rebuilt on every
  /// publish (`effectiveEpisodes` filters, `torrentFilesOf` parses the poll)
  /// and identity there would fail on every 3 s tick for no change at all.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PanelData &&
        identical(sources, other.sources) &&
        currentSourceIndex == other.currentSourceIndex &&
        mapEquals(probes, other.probes) &&
        setEquals(failedSources, other.failedSources) &&
        setEquals(playedSources, other.playedSources) &&
        qualityFilteredFallback == other.qualityFilteredFallback &&
        listEquals(episodes, other.episodes) &&
        currentEpisode == other.currentEpisode &&
        _sameFiles(files, other.files) &&
        currentFileIndex == other.currentFileIndex &&
        subtitleTarget == other.subtitleTarget;
  }

  @override
  int get hashCode => Object.hash(
    identityHashCode(sources),
    currentSourceIndex,
    Object.hashAllUnordered(
      probes.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    Object.hashAllUnordered(failedSources),
    Object.hashAllUnordered(playedSources),
    qualityFilteredFallback,
    Object.hashAll(episodes),
    currentEpisode,
    Object.hashAll(files.map((f) => Object.hash(f.index, f.name, f.sizeBytes))),
    currentFileIndex,
    subtitleTarget,
  );

  /// [TorrentFile] has no `==`; the three fields are the whole object.
  static bool _sameFiles(List<TorrentFile> a, List<TorrentFile> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x.index != y.index ||
          x.name != y.name ||
          x.sizeBytes != y.sizeBytes) {
        return false;
      }
    }
    return true;
  }

  @override
  String toString() =>
      'PanelData(sources: ${sources.length}, current: $currentSourceIndex, '
      'probes: $probes, failed: $failedSources, played: $playedSources, '
      'fallback: $qualityFilteredFallback, '
      'episodes: ${episodes.length}, currentEpisode: ${currentEpisode?.name}, '
      'files: ${files.length}, currentFile: $currentFileIndex, '
      'subtitleTarget: $subtitleTarget)';
}
