/// Registering a stream's side-car subtitles with the engine without letting
/// arrival order decide which language the viewer gets.
///
/// [VlcPlayerController.addSubtitle] maps onto libVLC's add-slave with the
/// select flag hardcoded `true` in every native backend, so each call enables
/// what it just added and a source shipping several side-cars ends up on
/// whichever add finished last.
///
/// Turning that flag into a parameter is a five-backend change, and restoring
/// the previous selection after each add would flash the wrong language on
/// screen, so instead the adds go out in a known order and the wanted track is
/// selected once, explicitly, at the end.
library;

import 'package:vlc_player/vlc_player.dart';

/// Adds [uris] to [controller] in order and leaves the [enable]-th of them
/// selected.
///
/// The adds are sequential on purpose: that is what makes the subtitle in
/// effect when this returns predictable at all.
///
/// [enable] indexes into [uris], not into the engine's track list. `null` means
/// the caller has no preference, and the last side-car stays on because the
/// select flag gives no way to ask otherwise.
///
/// New side-car tracks are identified by diffing the engine's subtitle list
/// around the batch: libVLC hands each slave a fresh id, so the ids that were
/// not there before are exactly these files, in the order they were added.
Future<void> addSideCarSubtitles(
  VlcPlayerController controller,
  List<Uri> uris, {
  int? enable,
}) async {
  if (uris.isEmpty) return;

  // Only worth a round-trip when the answer changes anything: if the last one
  // is wanted, VLC's select flag has already delivered it.
  //
  // The round trip also has to be possible at all. Until a VlcPlayer is built
  // the controller has no view id, and every call needing one throws - so on
  // the first open of a session this read escaped the function, failed the
  // open, and left the viewer looking at "Playback failed" for a video whose
  // only problem was which subtitle to preselect. The adds below are queued
  // and replayed on attach regardless, so refusing here costs the reorder and
  // nothing else: the last side-car stays selected rather than the preferred
  // language.
  final wantsEarlier =
      enable != null &&
      enable >= 0 &&
      enable < uris.length - 1 &&
      controller.isAttached;
  final before = wantsEarlier
      ? (await controller.getSubtitleTracks()).map((t) => t.id).toSet()
      : const <int>{};

  for (final uri in uris) {
    await controller.addSubtitle(uri);
  }
  if (!wantsEarlier) return;

  final added = (await controller.getSubtitleTracks())
      .where((t) => !before.contains(t.id))
      .toList();
  if (enable < added.length) {
    await controller.setSubtitleTrack(added[enable].id);
  }
}

/// Index of the first entry in [languages] written in [preferred], or `null`
/// when nothing matches.
///
/// Tags are compared on their primary subtag only, so a `pt-BR` side-car
/// satisfies a `pt` preference. Three-letter ISO 639-2 tags are deliberately
/// not folded into their two-letter forms: the mapping is not derivable, so
/// source metadata has to be normalised where it is parsed instead.
int? preferredSubtitleIndex(List<String?> languages, String? preferred) {
  final want = _primarySubtag(preferred);
  if (want == null) return null;
  for (var i = 0; i < languages.length; i++) {
    if (_primarySubtag(languages[i]) == want) return i;
  }
  return null;
}

/// Lowercased language part of a BCP 47-ish tag, or `null` when the tag says
/// nothing; `und` is what sources emit for an unknown language.
String? _primarySubtag(String? tag) {
  if (tag == null) return null;
  final primary = tag.trim().toLowerCase().split(RegExp('[-_]')).first;
  if (primary.isEmpty || primary == 'und') return null;
  return primary;
}
