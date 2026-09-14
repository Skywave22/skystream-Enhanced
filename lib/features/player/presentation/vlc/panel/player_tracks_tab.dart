/// The Audio and Subtitles tabs.
///
/// The engine owns both the track list and the selection: nothing here caches,
/// mirrors or merges either. `VlcPlayerValue.activeAudioTrackId` and
/// `activeSubtitleTrackId` say which track is rendering right now, every
/// native re-sends its snapshot after a set/disable/add, and the tick is read
/// straight off the controller, so a set the engine refuses never moves it.
/// `null` is "none" - libVLC's `-1` is normalised in the package.
///
/// A row's `onTap` is unawaited, so every engine call goes through `_setTrack`
/// or `_step`, which absorb the refusal rather than throw it into the zone. A
/// refused set also re-reads the list, because a refusal is the engine saying
/// the row should not have been there. Nothing re-reads after `addSubtitle` -
/// see [PlayerTracksTab.onTracksChanged].
///
/// What this adds over the engine is naming. libVLC hands back `Track 3` far
/// more often than it hands back anything a viewer could choose between, so
/// the language and codec from `getMediaInfo` are folded in beside the
/// description — see [trackLabel].
///
/// Focus lands once, on open, on the row that is active then: Flutter applies
/// an autofocus only while the scope has no focused child, so a row that
/// autofocuses on a later rebuild is harmless and needs no bookkeeping. That
/// row also has to be on screen, and a lazily-inflated list never runs its
/// builder for a row twenty down, so both lists go through
/// [PanelAnchoredList], which seeds the opening offset from the anchor,
/// centres it against real geometry a frame later and rescues focus into the
/// list if no row took it. The tab's job is to say which flattened child index
/// the anchor is - see `_list`.
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:vlc_player/vlc_player.dart';

import '../../../../../l10n/generated/app_localizations.dart';
import '../../../domain/subtitle_search_target.dart';
import '../player_value_selector.dart';
import '../vlc_subtitle_search_sheet.dart';
import 'player_anchored_list.dart';
import 'player_panel_labels.dart';
import 'player_panel_row.dart';

/// Which list a tab is showing. The two differ by more than a title: only
/// subtitles have an Off and two ways to add a track from outside.
enum PlayerTrackKind { audio, subtitle }

/// How far one press of a delay stepper moves. A tenth of a second is the
/// finest a viewer can judge against the picture, and the same step serves
/// audio and subtitle delay alike.
const Duration kSubtitleDelayStep = Duration(milliseconds: 100);

/// How far a held key moves per repeat. Half a second is the largest step
/// that cannot overshoot a badly muxed track in one go, and at a remote's
/// repeat rate it crosses two seconds in one lean.
const Duration kSubtitleDelayCoarseStep = Duration(milliseconds: 500);

Duration delayStepFor(PanelStep step) => switch (step) {
  PanelStep.fine => kSubtitleDelayStep,
  PanelStep.coarse => kSubtitleDelayCoarseStep,
};

/// The stepper's read-out for a delay: whole milliseconds under a second
/// (`+100ms`, `-500ms`), one decimal of seconds from there (`+1.5s`). Always
/// signed, so `+0ms` reads as a state and not a blank.
String delayLabel(Duration delay) {
  final ms = delay.inMilliseconds;
  final sign = ms < 0 ? '-' : '+';
  final magnitude = ms.abs();
  if (magnitude < 1000) return '$sign${magnitude}ms';
  return '$sign${(magnitude / 1000).toStringAsFixed(1)}s';
}

class PlayerTracksTab extends StatelessWidget {
  const PlayerTracksTab({
    required this.controller,
    required this.kind,
    required this.tracks,
    required this.trackInfo,
    required this.onTracksChanged,
    this.target,
    this.isTv = false,
    this.autofocus = false,
    super.key,
  });

  final VlcPlayerController controller;
  final PlayerTrackKind kind;

  /// The engine's own descriptions, in the engine's own order.
  final List<VlcTrackDescription> tracks;

  /// `getMediaInfo`'s view of the same tracks, which carries the codec and
  /// channel count the descriptions lack. Correlated by position because that
  /// is the only correlation libVLC offers; a short list simply means the tail
  /// rows show no detail.
  final List<VlcMediaTrackInfo> trackInfo;

  /// Asks the panel to read both track lists from the engine again.
  ///
  /// Not fired after an add, which is the one moment it looks due. libVLC 3's
  /// add-slave is queued to the input thread: `addSubtitle` returns once the
  /// request is posted, not once the ES exists, so a list read in the same
  /// turn is still the pre-add one, and publishing it would re-anchor the list
  /// and the D-pad focus on the wrong row ([PanelAnchoredList] re-centres on
  /// every reload).
  ///
  /// The reload waits for the engine instead. Every native moves
  /// `trackRevision` when the ES actually lands, and the panel re-reads on
  /// that revision without being asked (player_panel.dart, `_onEngine`).
  ///
  /// What is left for this callback is Retry - the manual fallback for an
  /// engine that never said - and a refused set, which means the list on
  /// screen is out of date (see `_setTrack`).
  final VoidCallback onTracksChanged;

  /// What the online search is about: the screen's title, ids and episode.
  /// Null for media the catalogue knows nothing of, where the engine's own
  /// metadata seeds a title-only search instead.
  final SubtitleSearchTarget? target;

  final bool isTv;
  final bool autofocus;

  bool get _isAudio => kind == PlayerTrackKind.audio;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // libVLC's own `Disable` pseudo-track. Subtitles get a real Off row below
    // and audio has no use for one, so it is never a row of its own.
    final listed = tracks.where((track) => track.id >= 0).toList();

    // The active id and the revision are the only two things in the value
    // this list draws from; a position tick every 250 ms is not a rebuild.
    return PlayerValueSelector<(int?, int)>(
      controller: controller,
      selector: (value) => (
        _isAudio ? value.activeAudioTrackId : value.activeSubtitleTrackId,
        value.trackRevision,
      ),
      builder: (context, selected) => _list(context, l10n, listed, selected.$1),
    );
  }

  Widget _list(
    BuildContext context,
    AppLocalizations l10n,
    List<VlcTrackDescription> listed,
    int? active,
  ) {
    // Focus has to land somewhere: the active row, or - when the engine names
    // nothing or names a track the list has not caught up with - Off for
    // subtitles and the first row for audio. The tick is stricter and follows
    // the engine alone.
    final known = active != null && listed.any((track) => track.id == active);

    // The same answers as positions in the flattened child list, which is what
    // [PanelAnchoredList] scrolls to. Only subtitles have an Off row ahead of
    // the tracks, and an empty list puts a note where they were.
    final leading = _isAudio ? 0 : 1;
    final retryIndex = leading + (listed.isEmpty ? 1 : listed.length);
    final anchor = known
        ? leading + listed.indexWhere((track) => track.id == active)
        : (_isAudio ? (listed.isEmpty ? retryIndex : 0) : 0);

    final children = <Widget>[
      if (!_isAudio)
        PanelRow(
          label: l10n.off,
          icon: Icons.subtitles_off_outlined,
          selected: active == null,
          autofocus: autofocus && anchor == 0,
          onTap: () =>
              unawaited(_setTrack(context, controller.disableSubtitle)),
        ),
      if (listed.isEmpty)
        PanelEmpty(
          text: _isAudio ? l10n.noAudioTracksReported : l10n.noSubtitlesFound,
        )
      else
        for (final (index, track) in listed.indexed)
          PanelRow(
            label: trackLabel(track, _infoFor(index), l10n),
            detail: trackDetail(_infoFor(index)),
            selected: active == track.id,
            autofocus: autofocus && anchor == leading + index,
            onTap: () => unawaited(
              _setTrack(
                context,
                () => _isAudio
                    ? controller.setAudioTrack(track.id)
                    : controller.setSubtitleTrack(track.id),
              ),
            ),
          ),
      // Tracks can arrive after the panel opened. The panel re-reads the list
      // when the engine's revision moves; this is the manual fallback for an
      // engine that did not say, and the only row an empty Audio tab has.
      PanelRow(
        label: l10n.retry,
        icon: Icons.refresh_rounded,
        autofocus: autofocus && anchor == retryIndex,
        onTap: onTracksChanged,
      ),
      if (_isAudio)
        ..._audioExtras(l10n)
      else
        ..._subtitleExtras(context, l10n),
    ];

    // The widget objects are built eagerly; handing them to the builder keeps
    // the elements lazy, which is why the anchor has to be scrolled to.
    return PanelAnchoredList(
      anchorIndex: anchor,
      // A one-line row is ~46 px and one carrying a codec detail ~60; the
      // middle keeps the anchor inside the viewport's 800 px cache for a far
      // longer list than either end would, and the frame-one centring corrects
      // it against real geometry anyway.
      estimatedRowExtent: 53,
      autofocus: autofocus,
      itemCount: children.length,
      itemBuilder: (context, index) => children[index],
    );
  }

  VlcMediaTrackInfo? _infoFor(int index) =>
      index < trackInfo.length ? trackInfo[index] : null;

  /// Runs the engine call behind a row tap - a set, or Off.
  ///
  /// Nothing here is optimistic, so a refusal needs no rollback; what it needs
  /// is somewhere to land. A row's `onTap` is unawaited and the app installs
  /// no `PlatformDispatcher.onError`, so a bare `controller.setAudioTrack(id)`
  /// hands its failure to the zone and it is a console trace and nothing else.
  ///
  /// A refusal also means the list has moved on - a stream renegotiated, a
  /// language dropped - since the id came from a list read once and held
  /// since. So the list is read again.
  Future<void> _setTrack(
    BuildContext context,
    Future<void> Function() call,
  ) async {
    try {
      await call();
    } on VlcPlayerException catch (_) {
      // The panel can be closed, or the list already re-read under us, while
      // the call is in flight; a reload then belongs to nobody.
      if (context.mounted) onTracksChanged();
    }
  }

  /// Runs a delay call. Same absorption as [_setTrack], and for the same
  /// reason, but no reload: the stepper reads
  /// `value.audioDelay`/`value.subtitleDelay`, so a refused delay is a
  /// read-out that does not move.
  Future<void> _step(Future<void> Function() call) async {
    try {
      await call();
    } on VlcPlayerException catch (_) {
      // Absorbed on purpose: see above.
    }
  }

  /// The one runtime adjustment libVLC exposes for audio: a delay against the
  /// picture, for a stream muxed out of step.
  List<Widget> _audioExtras(AppLocalizations l10n) {
    return <Widget>[
      PanelSubheader(title: l10n.audioDelay),
      _delayStepper(
        label: l10n.audioDelay,
        select: (value) => value.audioDelay,
        apply: controller.setAudioDelay,
      ),
    ];
  }

  /// The two ways a subtitle the stream does not carry gets into the engine,
  /// and the one runtime adjustment libVLC exposes.
  ///
  /// Both entry points end at `addSubtitle`, which makes the file a real
  /// track, so neither needs anywhere to put its result: it is in the list
  /// above the next time the list is read.
  List<Widget> _subtitleExtras(BuildContext context, AppLocalizations l10n) {
    return <Widget>[
      PanelSubheader(title: l10n.subtitleOptions),
      PanelRow(
        label: l10n.loadSubtitleFile,
        icon: Icons.file_open_outlined,
        onTap: () => unawaited(_loadFromDevice()),
      ),
      PanelRow(
        label: l10n.searchSubtitlesOnline,
        icon: Icons.search_rounded,
        onTap: () => unawaited(_searchOnline(context)),
      ),
      _delayStepper(
        label: l10n.subtitleDelay,
        select: (value) => value.subtitleDelay,
        apply: controller.setSubtitleDelay,
      ),
    ];
  }

  /// A delay stepper that follows the engine's own value - the natives echo a
  /// delay on the next snapshot - and rebuilds on that alone, not on every
  /// position tick.
  Widget _delayStepper({
    required String label,
    required Duration Function(VlcPlayerValue value) select,
    required Future<void> Function(Duration delay) apply,
  }) {
    return PlayerValueSelector<Duration>(
      controller: controller,
      selector: select,
      builder: (context, delay) => PanelStepperRow(
        label: label,
        value: delayLabel(delay),
        onDecrease: (step) =>
            unawaited(_step(() => apply(delay - delayStepFor(step)))),
        onIncrease: (step) =>
            unawaited(_step(() => apply(delay + delayStepFor(step)))),
        onReset: delay == Duration.zero
            ? null
            : () => unawaited(_step(() => apply(Duration.zero))),
      ),
    );
  }

  Future<void> _loadFromDevice() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const <String>['srt', 'vtt', 'ass', 'ssa', 'sub'],
    );
    final path = picked?.path;
    if (path == null) return;
    try {
      await controller.addSubtitle(Uri.file(path));
    } on VlcPlayerException catch (_) {
      // A file the engine will not take. Absorbed like every other engine
      // call here (see [_setTrack]): the handler is unawaited, and the list is
      // about to say the track is not there.
    }
    // Deliberately no reload here - see the note on [onTracksChanged].
  }

  Future<void> _searchOnline(BuildContext context) async {
    final seed = await _searchSeed();
    if (!context.mounted) return;
    // The panel stays up either way: a viewer who backed out of the search
    // still wants the track list they opened it from. What the sheet returns
    // is not acted on: it ends at the same queued `addSubtitle`, so re-reading
    // on its word has the problem described on [onTracksChanged].
    await VlcSubtitleSearchSheet.show(
      context,
      controller,
      target: seed,
      isTv: isTv,
    );
  }

  /// The screen's target when it has one; otherwise the engine's title alone,
  /// so a local file keeps its filename as the seed and nothing fires on open.
  Future<SubtitleSearchTarget?> _searchSeed() async {
    final given = target;
    if (given != null) return given;
    try {
      final title = (await controller.getMediaInfo()).title;
      return SubtitleSearchTarget(title: title ?? '');
    } catch (_) {
      // A seed is a convenience; an engine that will not answer is not a
      // reason to refuse to open the search.
      return null;
    }
  }
}
