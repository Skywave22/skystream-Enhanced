/// What one row of a source list says about its source: two facts, shown
/// side by side and never merged.
///
/// [SourceReachability] is what the reachability check found before anything
/// was opened. [SourcePlayState] is what happened when the source was played.
/// Merging them - playing winning - made the row being opened stop saying it
/// was reachable, so it read as less proven than the rows beneath it that had
/// passed the same check.
///
/// The startup screen and the in-player Sources panel both render rows from
/// these, so the same source can never read two ways in two places.
library;

import '../../../core/domain/entity/multimedia_item.dart';
import 'stream_resolver.dart';

enum SourceReachability {
  /// The reachability check is out for it.
  checking,

  /// The check got an answer from it.
  reachable,

  /// The check got no answer from it.
  unreachable,

  /// Nobody has asked: the check only looks at the top few sources, and
  /// cannot look at a torrent or a local file at all. Not "unknown", which
  /// would read as a verdict.
  notChecked,
}

enum SourcePlayState {
  /// Not opened this resolve.
  untried,

  /// Handed to the engine, no picture yet.
  opening,

  /// On screen now.
  playing,

  /// Opened this resolve and would not play, or stopped.
  failed,
}

/// The provider [stream] names, or null when it names none.
///
/// `Unknown` is [StreamResult]'s placeholder for a source whose plugin named
/// no provider - every JS plugin's stream is one - and not a provider's name.
/// Shown, it put "Unknown ·" in front of every startup row and an "Unknown"
/// line under every Sources row.
String? sourceProvider(StreamResult stream) {
  final provider = stream.providerName.trim();
  if (provider.isEmpty || provider == 'Unknown') return null;
  return provider;
}

/// The name a source row gives [stream]: the plugin's own label for it, led
/// by the provider when one was named.
String sourceRowLabel(StreamResult stream) {
  final provider = sourceProvider(stream);
  return provider == null ? stream.source : '$provider · ${stream.source}';
}

/// What is known about reaching [stream]: the [probe] outcome the check
/// reported, unless [hasPlayed] - it has shown a picture this resolve, which
/// is stronger evidence than any request about it.
SourceReachability sourceReachabilityOf(
  StreamResult stream,
  ProbeOutcome? probe, {
  bool hasPlayed = false,
}) {
  // A source on screen was reached, whatever the probe said - or could not
  // say. Otherwise a playing torrent read "not checked", and a slow host the
  // probe gave up on read "unreachable" under its own picture.
  if (hasPlayed) return SourceReachability.reachable;
  // The probe passes these without asking, so its pass says nothing.
  if (isUncheckableSource(stream)) return SourceReachability.notChecked;
  return switch (probe) {
    null => SourceReachability.notChecked,
    ProbeOutcome.trying => SourceReachability.checking,
    ProbeOutcome.healthy => SourceReachability.reachable,
    ProbeOutcome.unhealthy => SourceReachability.unreachable,
  };
}

/// What playing a source has come to.
///
/// [isCurrent] names the source the player is on, and [hasPicture] whether
/// that attempt has produced a frame. Pass false for [isCurrent] when nothing
/// is being played, such as once every source has failed. [failed] is this
/// session's record of the source not playing.
SourcePlayState sourcePlayStateOf({
  required bool isCurrent,
  required bool hasPicture,
  required bool failed,
}) {
  // Ahead of [failed]: a source picked again is being tried again.
  if (isCurrent) {
    return hasPicture ? SourcePlayState.playing : SourcePlayState.opening;
  }
  return failed ? SourcePlayState.failed : SourcePlayState.untried;
}
