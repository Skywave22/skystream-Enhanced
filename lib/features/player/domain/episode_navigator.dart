/// Which episode plays after this one, and which played before it.
///
/// A pure function of the item and the current episode — no engine, no
/// storage, no providers.
///
/// `MultimediaItem` sorts episodes by (season, episode) only, so on an anime
/// carrying both subbed and dubbed entries the two copies of episode 5 sit
/// adjacent and a naive `index + 1` advances from subbed 5 to dubbed 5 — the
/// same episode, in a language the viewer did not choose. That is why the dub
/// filter is not optional.
///
/// [NextEpisodeLookup] also keeps "the series ended" apart from "the current
/// episode could not be located", because a caller that conflates the two
/// deletes a series from history on a mid-series lookup failure.
library;

import '../../../core/domain/entity/multimedia_item.dart';

/// The outcome of asking for the next episode.
class NextEpisodeLookup {
  const NextEpisodeLookup._({required this.next, required this.currentFound});

  const NextEpisodeLookup.notApplicable() : next = null, currentFound = false;

  /// The episode to play next, or null when there is none to play.
  final Episode? next;

  /// Whether the current episode was located in the list at all.
  ///
  /// False means the answer is "don't know", not "nothing follows". Callers
  /// must not treat it as the end of the series.
  final bool currentFound;

  /// The current episode was found, and nothing follows it.
  ///
  /// The only condition under which treating the series as finished is safe.
  bool get isFinalEpisode => currentFound && next == null;
}

/// The episode list to navigate, filtered to one dub track when the series
/// carries both.
///
/// Falls back to the unfiltered list whenever filtering would produce nothing,
/// so a mislabelled list degrades to "wrong order" rather than "no next
/// episode".
List<Episode> effectiveEpisodes(MultimediaItem item, Episode? current) {
  final episodes = item.episodes;
  if (episodes == null || episodes.isEmpty) return const <Episode>[];
  if (!_isSeries(item)) return episodes;

  final hasSubbed = episodes.any((e) => e.dubStatus == DubStatus.subbed);
  final hasDubbed = episodes.any((e) => e.dubStatus == DubStatus.dubbed);
  if (!hasSubbed || !hasDubbed) return episodes;

  if (current == null || current.dubStatus == DubStatus.none) return episodes;
  final filtered = episodes
      .where((e) => e.dubStatus == current.dubStatus)
      .toList();
  return filtered.isEmpty ? episodes : filtered;
}

/// Resolves what follows [current] for [item].
///
/// [videoUrl] is the route's token, used as a last resort to locate the current
/// episode when [current] is null or absent from the list.
NextEpisodeLookup nextEpisodeFor({
  required MultimediaItem item,
  required Episode? current,
  required String videoUrl,
}) {
  if (!_isSeries(item)) return const NextEpisodeLookup.notApplicable();

  final episodes = effectiveEpisodes(item, current);
  if (episodes.isEmpty) return const NextEpisodeLookup.notApplicable();

  final index = _indexOf(episodes, current, videoUrl);

  if (index == -1) {
    // Current episode not located: the honest answer is "unknown".
    return const NextEpisodeLookup.notApplicable();
  }
  if (index >= episodes.length - 1) {
    return const NextEpisodeLookup._(next: null, currentFound: true);
  }
  return NextEpisodeLookup._(next: episodes[index + 1], currentFound: true);
}

/// The episode before [current], or null when there is none to play.
///
/// Deliberately not a [NextEpisodeLookup]. That type exists to keep "the
/// series ended" apart from "the current episode could not be located",
/// because conflating them deletes a series from history. Nothing follows
/// from not finding a previous episode except that the button is absent, so
/// the two answers can be the same null.
Episode? previousEpisodeFor({
  required MultimediaItem item,
  required Episode? current,
  required String videoUrl,
}) {
  if (!_isSeries(item)) return null;

  final episodes = effectiveEpisodes(item, current);
  if (episodes.isEmpty) return null;

  final index = _indexOf(episodes, current, videoUrl);
  if (index <= 0) return null;
  return episodes[index - 1];
}

/// Where [current] sits in [episodes], or -1 when it cannot be placed.
///
/// Shared by both directions so they can never disagree about which episode is
/// playing - a previous button that located it differently from the advance
/// would walk a different list.
int _indexOf(List<Episode> episodes, Episode? current, String videoUrl) {
  var index = -1;
  if (current != null) {
    index = episodes.indexWhere((e) => e.url == current.url);
    // A filtered list can drop the exact object the caller held, and some
    // plugins hand back a different URL for the same episode, so fall back to
    // the numbering when it is actually populated.
    if (index == -1 && current.season > 0 && current.episode > 0) {
      index = episodes.indexWhere(
        (e) => e.season == current.season && e.episode == current.episode,
      );
    }
  }
  if (index == -1) {
    index = episodes.indexWhere((e) => e.url == videoUrl);
  }
  return index;
}

bool _isSeries(MultimediaItem item) =>
    item.contentType == MultimediaContentType.series ||
    item.contentType == MultimediaContentType.anime;
