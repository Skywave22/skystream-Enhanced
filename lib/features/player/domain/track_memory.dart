/// Carrying an audio or subtitle choice across a reopen.
///
/// A failover, a recovery and a rendition step-down all re-open media under a
/// viewer who did nothing. The reopen restores the position and, until this
/// existed, nothing else - so the audio and subtitles went back to whatever the
/// engine picks for itself, which is what a viewer watching a dubbed film or
/// reading subtitles notices immediately.
///
/// Ids alone cannot carry the choice. A recovery of the same file keeps them,
/// but a failover moves to a different provider's file where id 3 means
/// something else entirely, and a rendition step-down can renumber. So a
/// remembered pick keeps the language and the name too, and the id is only the
/// first thing tried.
library;

import 'package:vlc_player/vlc_player.dart';

/// A track the viewer was listening to or reading before a reopen.
class RememberedTrack {
  /// Creates a remembered pick.
  const RememberedTrack({required this.id, this.language, this.name});

  /// Snapshots [description], or null when there is nothing selected.
  static RememberedTrack? of(VlcTrackDescription? description) =>
      description == null
      ? null
      : RememberedTrack(
          id: description.id,
          language: description.language,
          name: description.name,
        );

  /// The engine id at the time it was chosen.
  final int id;

  /// The track's language tag, when the source declared one.
  final String? language;

  /// The track's display name, used only when there is no language to go on.
  final String? name;
}

/// Lowercased primary subtag, or null when the tag says nothing.
///
/// `und` is what sources emit for "unknown", so it matches nothing rather than
/// matching every other unknown track.
String? _primarySubtag(String? tag) {
  if (tag == null) return null;
  final primary = tag.trim().toLowerCase().split(RegExp('[-_]')).first;
  if (primary.isEmpty || primary == 'und') return null;
  return primary;
}

/// The track in [available] that best answers [remembered], or null when
/// nothing does.
///
/// Tried in order of how much each signal proves:
///
///  1. The same id AND the same language. A recovery of the same file, where
///     the id genuinely still means what it meant.
///  2. The same language. A failover to another provider's copy of the same
///     film, where ids are meaningless but "the French track" still is. The
///     first match wins, which is the order the source lists them in.
///  3. The same name, for a source that declares no language at all - common
///     on scraped releases where the only label is "AAC 5.1 Hindi".
///  4. The same id, when the remembered pick had neither language nor name.
///
/// Deliberately no positional fallback. "Whatever is second in the list" is a
/// guess, and a wrong audio track is worse than the engine's own default -
/// which is what returning null leaves in place.
VlcTrackDescription? matchRememberedTrack(
  List<VlcTrackDescription> available,
  RememberedTrack? remembered,
) {
  if (remembered == null || available.isEmpty) return null;

  final wanted = _primarySubtag(remembered.language);

  if (wanted != null) {
    for (final track in available) {
      if (track.id == remembered.id &&
          _primarySubtag(track.language) == wanted) {
        return track;
      }
    }
    for (final track in available) {
      if (_primarySubtag(track.language) == wanted) return track;
    }
    // The language was known and is gone from this source. Falling back to the
    // id here would hand over an unrelated track that merely shares a number.
    return null;
  }

  final name = remembered.name?.trim();
  if (name != null && name.isNotEmpty) {
    for (final track in available) {
      if (track.name.trim() == name) return track;
    }
  }

  for (final track in available) {
    if (track.id == remembered.id) return track;
  }
  return null;
}
