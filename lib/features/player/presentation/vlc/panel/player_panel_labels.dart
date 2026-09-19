/// The text the side panel puts in front of the viewer.
///
/// Pure functions over data the app already has, kept out of the widgets so the
/// awkward half — what a plugin's source string actually looks like, and what
/// libVLC leaves out of a track description — is testable without a tree.
library;

import 'package:vlc_player/vlc_player.dart';

import '../../../../../core/domain/entity/multimedia_item.dart';
import '../../../../../core/utils/stream_quality_sorter.dart';
import '../../../../../l10n/generated/app_localizations.dart';
import '../../../domain/source_row_status.dart';

/// The word a source row shows for what the reachability check found. Shared
/// by the startup screen's list and the Sources tab, which render it
/// differently but must never name it differently.
String sourceReachabilityLabel(
  AppLocalizations l10n,
  SourceReachability reachability,
) => switch (reachability) {
  SourceReachability.checking => l10n.playerSourceChecking,
  SourceReachability.reachable => l10n.playerSourceReachable,
  // "Unknown", not "unreachable": the check got no answer, which a slow host
  // or one that refuses test requests gives too, and such a link can still
  // play. The word claims no more than the check knows.
  SourceReachability.unreachable => l10n.unknown,
  SourceReachability.notChecked => l10n.playerSourceNotChecked,
};

/// The word a source row shows for how playing it went, or null for a source
/// nobody has opened, which has nothing to say about it.
String? sourcePlayStateLabel(AppLocalizations l10n, SourcePlayState state) =>
    switch (state) {
      SourcePlayState.untried => null,
      SourcePlayState.opening => l10n.playerSourceOpening,
      SourcePlayState.playing => l10n.playing,
      SourcePlayState.failed => l10n.playerSourceUnplayable,
    };

/// What a source row can say about itself.
///
/// Everything but [title] is optional because a plugin owes us nothing: some
/// return `1080p`, some return four lines of release-group noise, and some
/// return the word `Server 2`.
class SourceFacts {
  const SourceFacts({
    required this.title,
    this.quality,
    this.size,
    this.seeders,
  });

  /// The source label with the facts below lifted out of it, so a row does not
  /// print `2.1 GB` twice.
  final String title;

  /// `1080p`, `4K` … or null where the label carries no resolution at all.
  /// [qualityBadgeLabel]'s `Auto` is not a quality and is dropped here.
  final String? quality;

  /// Human-readable size, normalised to one decimal and an upper-case unit.
  final String? size;

  final int? seeders;
}

/// Anything that looks like a file size in a source label. Torrent indexers
/// write `2.1 GB`, `2,1GiB` and `700 mb` interchangeably.
final RegExp _sizeExpression = RegExp(
  r'(\d+(?:[.,]\d+)?)\s*(?:([KMGT])i?B)\b',
  caseSensitive: false,
);

/// Seeder counts, in the three shapes the indexers actually use: the person
/// emoji Torrentio prefers, a spelled-out word, or an `S:` prefix. Deliberately
/// not a bare `S12` — that matches season numbers.
final RegExp _seederExpression = RegExp(
  r'(?:\u{1F464}|\u{1F465}|\u{1F331})\s*(\d+)'
  r'|(\d+)\s*seed(?:er)?s?\b'
  r'|\bseed(?:er)?s?\s*[:=]?\s*(\d+)'
  r'|\bS\s*[:=]\s*(\d+)',
  caseSensitive: false,
  unicode: true,
);

/// Reads what a row can show out of [stream]'s label.
SourceFacts sourceFactsOf(StreamResult stream) {
  final raw = stream.source;
  final size = _sizeExpression.firstMatch(raw);
  final seeders = _seederExpression.firstMatch(raw);
  final badge = qualityBadgeLabel(stream);

  var title = raw;
  // Longest match first: removing the earlier one shifts the later one's
  // offsets, and these two overlap often enough on a torrent label to matter.
  for (final match in <RegExpMatch?>[
    size,
    seeders,
  ].nonNulls.toList()..sort((a, b) => b.start.compareTo(a.start))) {
    title = title.replaceRange(match.start, match.end, ' ');
  }

  return SourceFacts(
    title: _tidy(title).isEmpty ? _tidy(raw) : _tidy(title),
    quality: badge == 'Auto' ? null : badge,
    size: size == null ? null : _formatSize(size),
    seeders: seeders == null ? null : _firstGroup(seeders),
  );
}

int? _firstGroup(RegExpMatch match) {
  for (var i = 1; i <= match.groupCount; i++) {
    final value = match.group(i);
    if (value != null) return int.tryParse(value);
  }
  return null;
}

String _formatSize(RegExpMatch match) {
  final value = double.tryParse(match.group(1)!.replaceAll(',', '.'));
  final unit = '${match.group(2)!.toUpperCase()}B';
  if (value == null) return '${match.group(1)}$unit';
  // Whole numbers keep no decimal: `2 GB`, not `2.0 GB`.
  final rounded = value >= 100 || value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(1);
  return '$rounded $unit';
}

/// Collapses the wreckage left by lifting facts out of a label: newlines,
/// double spaces, and separators that now separate nothing.
String _tidy(String value) {
  return value
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'(\s*[·•|/-]\s*){2,}'), ' · ')
      .replaceAll(RegExp(r'^(\s*[·•|/-]\s*)+'), '')
      .replaceAll(RegExp(r'(\s*[·•|/-]\s*)+$'), '')
      .trim();
}

/// A name for a track the engine has not named.
///
/// libVLC hands back `Track 3` — or nothing at all — far more often than it
/// hands back `English (AC3 5.1)`, and a list of numbered rows is not a choice
/// anybody can make. The language is the next best identity, and it arrives on
/// the description or, when the description is bare, on the media info entry
/// beside it.
String trackLabel(
  VlcTrackDescription track,
  VlcMediaTrackInfo? info,
  AppLocalizations l10n,
) {
  final name = track.name.trim();
  if (name.isNotEmpty && !_isPlaceholderName(name)) return name;

  final language = _languageName(track.language ?? info?.language);
  if (language != null) return language;

  // A named-but-placeholder track still beats inventing a number of our own:
  // `Track 3` from the engine and `Track 3` from us are the same row.
  return name.isEmpty ? l10n.playerTrackNumber(track.id) : name;
}

/// The second line: codec, channels and bitrate, whichever of them exist.
///
/// Never the whole of what VLC knows — a row that wraps is worse than a row
/// that omits the sample rate.
String? trackDetail(VlcMediaTrackInfo? info) {
  if (info == null) return null;
  final parts = <String>[
    ?_codecName(info.codec),
    ?_channelName(info.channels),
    ?_bitrateName(info.bitrate),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Whether [name] is the engine counting rather than naming.
bool _isPlaceholderName(String name) => RegExp(
  r'^(audio |subtitle |spu )?track\s*#?\d*$',
  caseSensitive: false,
).hasMatch(name);

String? _codecName(String? codec) {
  final value = codec?.trim();
  if (value == null || value.isEmpty) return null;
  // FourCCs read as noise in title case; every codec name here is an acronym.
  return value.toUpperCase();
}

String? _channelName(int? channels) => switch (channels) {
  null || <= 0 => null,
  1 => 'Mono',
  2 => 'Stereo',
  6 => '5.1',
  8 => '7.1',
  final int other => '$other ch',
};

String? _bitrateName(int? bitrate) {
  // VLC reports 0 for "did not find out", which is not a bitrate.
  if (bitrate == null || bitrate < 1000) return null;
  return '${(bitrate / 1000).round()} kbps';
}

/// The languages a stream is realistically in, by both ISO 639-1 and 639-2.
///
/// Not a complete table on purpose: the fallback prints the code the engine
/// gave, which is honest, whereas a half-remembered mapping is not.
const Map<String, String> _languageNames = <String, String>{
  'ar': 'Arabic',
  'ara': 'Arabic',
  'bg': 'Bulgarian',
  'bul': 'Bulgarian',
  'bn': 'Bengali',
  'ben': 'Bengali',
  'cs': 'Czech',
  'cze': 'Czech',
  'ces': 'Czech',
  'da': 'Danish',
  'dan': 'Danish',
  'de': 'German',
  'ger': 'German',
  'deu': 'German',
  'el': 'Greek',
  'gre': 'Greek',
  'ell': 'Greek',
  'en': 'English',
  'eng': 'English',
  'es': 'Spanish',
  'spa': 'Spanish',
  'fa': 'Persian',
  'per': 'Persian',
  'fas': 'Persian',
  'fi': 'Finnish',
  'fin': 'Finnish',
  'fr': 'French',
  'fre': 'French',
  'fra': 'French',
  'he': 'Hebrew',
  'heb': 'Hebrew',
  'hi': 'Hindi',
  'hin': 'Hindi',
  'hr': 'Croatian',
  'hrv': 'Croatian',
  'hu': 'Hungarian',
  'hun': 'Hungarian',
  'id': 'Indonesian',
  'ind': 'Indonesian',
  'it': 'Italian',
  'ita': 'Italian',
  'ja': 'Japanese',
  'jpn': 'Japanese',
  'ko': 'Korean',
  'kor': 'Korean',
  'ml': 'Malayalam',
  'mal': 'Malayalam',
  'ms': 'Malay',
  'may': 'Malay',
  'msa': 'Malay',
  'nl': 'Dutch',
  'dut': 'Dutch',
  'nld': 'Dutch',
  'no': 'Norwegian',
  'nor': 'Norwegian',
  'pl': 'Polish',
  'pol': 'Polish',
  'pt': 'Portuguese',
  'por': 'Portuguese',
  'ro': 'Romanian',
  'rum': 'Romanian',
  'ron': 'Romanian',
  'ru': 'Russian',
  'rus': 'Russian',
  'sv': 'Swedish',
  'swe': 'Swedish',
  'ta': 'Tamil',
  'tam': 'Tamil',
  'te': 'Telugu',
  'tel': 'Telugu',
  'th': 'Thai',
  'tha': 'Thai',
  'tr': 'Turkish',
  'tur': 'Turkish',
  'uk': 'Ukrainian',
  'ukr': 'Ukrainian',
  'vi': 'Vietnamese',
  'vie': 'Vietnamese',
  'zh': 'Chinese',
  'chi': 'Chinese',
  'zho': 'Chinese',
};

String? _languageName(String? language) {
  final value = language?.trim();
  if (value == null || value.isEmpty || value.toLowerCase() == 'und') {
    return null;
  }
  final mapped = _languageNames[value.toLowerCase()];
  if (mapped != null) return mapped;
  // Already a name rather than a code, most likely: `Brazilian Portuguese`.
  if (value.length > 3) return value;
  return value.toUpperCase();
}
