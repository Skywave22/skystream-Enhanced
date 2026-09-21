/// The Files tab — which file inside a season-pack torrent is playing.
///
/// The list and its parsing stay in torrent_file_sheet.dart, whose shape is the
/// torrent server's rather than the player's. This is only the presentation of
/// it, folded in here because a forty-episode pack in a bottom sheet has
/// exactly the problem the panel exists to fix.
library;

import 'player_anchored_list.dart';

import 'package:flutter/material.dart';

import '../../../../../l10n/generated/app_localizations.dart';
import '../torrent_file_sheet.dart';
import 'player_panel_row.dart';

class PlayerFilesTab extends StatelessWidget {
  const PlayerFilesTab({
    required this.files,
    required this.onPick,
    this.currentIndex,
    this.anchorIndex,
    this.autofocus = false,
    super.key,
  });

  final List<TorrentFile> files;

  /// The server's file id currently being streamed, not a list position.
  /// Drives the tick and follows live data.
  final int? currentIndex;

  /// The server's file id of the row the list opens on and, with [autofocus],
  /// focuses — an id like [currentIndex], not a position. Defaults to
  /// [currentIndex]; the panel passes the value it saw at open.
  final int? anchorIndex;

  final ValueChanged<TorrentFile> onPick;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (files.isEmpty) return PanelEmpty(text: l10n.noResultsFound);

    // The id has to be looked up: `TorrentFile.index` is the server's id and
    // the list is filtered, so with ids above `files.length` treating it as a
    // position would seed the scroll past the end of the list.
    final anchorId = anchorIndex ?? currentIndex;
    final found = files.indexWhere((file) => file.index == anchorId);
    // Before the server has said which file it picked there is no current
    // row, and the first one is the honest place to start.
    final anchor = found < 0 ? 0 : found;

    return PanelAnchoredList(
      anchorIndex: anchor,
      // A one-line row with a size badge; measured in
      // player_anchored_list_test.dart.
      estimatedRowExtent: 70,
      autofocus: autofocus,
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: files.length,
      itemBuilder: (context, position) {
        final file = files[position];
        final current = file.index == currentIndex;
        return PanelRow(
          label: file.name,
          badges: <String>[?_size(file)],
          icon: Icons.video_file_outlined,
          selected: current,
          selectedLabel: l10n.playing,
          autofocus: autofocus && position == anchor,
          onTap: () => onPick(file),
        );
      },
    );
  }

  String? _size(TorrentFile file) {
    final bytes = file.sizeBytes;
    if (bytes == null || bytes <= 0) return null;
    const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 10 || unit == 0 ? 0 : 1)}'
        ' ${units[unit]}';
  }
}
