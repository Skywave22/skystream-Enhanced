/// Choosing which file inside a torrent to play.
///
/// A season pack is one magnet holding a dozen episodes, and the torrent server
/// picks one of them on its own. Without this the viewer watches whatever it
/// picked, for the whole life of the download:
/// `TorrentService.getStreamUrlForFileIndex` has existed the entire time and
/// the only route to it (addon_playback_resolver.dart:104) has no callers.
///
/// Parsing lives here rather than in the screen because the shape is the
/// torrent server's, not the player's: `file_stats` is a list of loosely typed
/// maps, every field of which can be missing on a torrent that has not finished
/// fetching metadata.
library;

import 'package:flutter/material.dart';

import '../../../../core/models/torrent_status.dart';
import '../widgets/hotstar_player_style.dart';

/// One playable file inside the active torrent.
class TorrentFile {
  const TorrentFile({required this.index, required this.name, this.sizeBytes});

  /// The server's own file id, which is what
  /// `getStreamUrlForFileIndex` takes — deliberately not this entry's position
  /// in the list, because the two diverge as soon as anything is filtered out.
  final int index;

  /// Leaf name. The full path is the release folder repeated on every row,
  /// which pushes the part that actually distinguishes them off screen.
  final String name;

  final int? sizeBytes;
}

/// Extensions a torrent's video files actually use. Season packs ship samples,
/// subtitles, `.nfo`s and cover art alongside the episodes, and offering those
/// as things to play is worse than offering nothing.
const Set<String> _kPlayableExtensions = <String>{
  'mkv',
  'mp4',
  'avi',
  'm4v',
  'mov',
  'ts',
  'webm',
  'wmv',
  'flv',
  'mpg',
  'mpeg',
};

/// Reads the playable files out of a torrent status, largest first is *not*
/// applied: the server's order is the torrent's order, which for a season pack
/// is episode order, and re-sorting it would be actively unhelpful.
List<TorrentFile> torrentFilesOf(TorrentStatus? status) {
  final raw = status?.data['file_stats'];
  if (raw is! List) return const <TorrentFile>[];

  final files = <TorrentFile>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final index = (entry['id'] as num?)?.toInt();
    final path = entry['path']?.toString();
    if (index == null || path == null || path.isEmpty) continue;
    final name = path.split(RegExp(r'[/\\]')).last;
    final extension = name.contains('.')
        ? name.split('.').last.toLowerCase()
        : '';
    if (!_kPlayableExtensions.contains(extension)) continue;
    files.add(
      TorrentFile(
        index: index,
        name: name,
        sizeBytes: (entry['length'] as num?)?.toInt(),
      ),
    );
  }
  return files;
}

/// A file picker over the torrent currently being seeded.
///
/// Resolves the chosen [TorrentFile], or null if the sheet was dismissed.
///
/// With [isTv] the sheet opens focused on the file that is playing (or the
/// first, before anything is), so the D-pad starts from where the viewer is
/// rather than spending a press finding the list.
Future<TorrentFile?> showTorrentFileSheet(
  BuildContext context, {
  required List<TorrentFile> files,
  required int? currentIndex,
  bool isTv = false,
  void Function(BuildContext sheetContext)? onOpened,
}) {
  final hasCurrent = files.any((f) => f.index == currentIndex);
  return showModalBottomSheet<TorrentFile>(
    context: context,
    backgroundColor: const Color(0xFF141414),
    isScrollControlled: true,
    builder: (sheetContext) {
      onOpened?.call(sheetContext);
      return SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: files.length,
          itemBuilder: (context, i) {
            final file = files[i];
            final selected = file.index == currentIndex;
            return ListTile(
              dense: true,
              autofocus: isTv && (selected || (!hasCurrent && i == 0)),
              selected: selected,
              selectedColor: Colors.white,
              leading: Icon(
                selected ? Icons.play_arrow_rounded : Icons.video_file_outlined,
                color: Colors.white70,
              ),
              title: Text(
                file.name,
                style: const TextStyle(color: Colors.white),
              ),
              subtitle: file.sizeBytes == null
                  ? null
                  : Text(
                      _humanSize(file.sizeBytes!),
                      style: const TextStyle(
                        color: HotstarPlayerStyle.mutedText,
                      ),
                    ),
              onTap: () => Navigator.of(sheetContext).pop(file),
            );
          },
        ),
      );
    },
  );
}

String _humanSize(int bytes) {
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
