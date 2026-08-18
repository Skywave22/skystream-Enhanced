import 'dart:async';
import 'dart:convert';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entity/multimedia_item.dart';
import '../models/addon_stream_source.dart';

part 'addon_playback_launcher.g.dart';

/// Which player add-on links open in.
enum AddonPlayerChoice {
  /// The app's own full-featured player: quality filtering, source switching,
  /// track/subtitle menus, gestures, HDR + tone mapping, external player
  /// hand-off, watch history and tracker sync.
  builtIn('Built-in player'),

  /// The lightweight add-on player (torrent stats overlay, binge rollover).
  addon('Add-on player');

  const AddonPlayerChoice(this.label);
  final String label;
}

/// Remembers which player the user prefers for add-on playback.
@Riverpod(keepAlive: true)
class AddonPlayerPreference extends _$AddonPlayerPreference {
  static const String _key = 'addon_player_choice';

  @override
  AddonPlayerChoice build() {
    Future.microtask(_load);
    return AddonPlayerChoice.builtIn;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_key);
      if (stored == AddonPlayerChoice.addon.name) {
        state = AddonPlayerChoice.addon;
      }
    } catch (_) {
      // Default stands.
    }
  }

  Future<void> set(AddonPlayerChoice choice) async {
    state = choice;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, choice.name);
    } catch (_) {
      // Non-fatal: the choice still applies for this session.
    }
  }
}

@Riverpod(keepAlive: true)
AddonStreamConverter addonStreamConverter(Ref ref) =>
    const AddonStreamConverter();

/// Maps add-on stream descriptors onto the app's own [StreamResult] model, so
/// add-on links can be played by the built-in player with every feature it
/// has — including its torrent handling, which understands magnet URLs.
class AddonStreamConverter {
  const AddonStreamConverter();

  /// [selected] is moved to the front so the built-in player starts on the
  /// row the user tapped, while the rest stay available in its Sources menu.
  List<StreamResult> toStreamResults(
    List<AddonStreamSource> sources, {
    AddonStreamSource? selected,
  }) {
    final ordered = <AddonStreamSource>[
      if (selected != null) selected,
      ...sources.where((s) => s.dedupeKey != selected?.dedupeKey),
    ];

    final out = <StreamResult>[];
    for (final source in ordered) {
      final url = source.url ?? source.magnetUri;
      if (url == null || url.isEmpty) continue;
      out.add(
        StreamResult(
          url: url,
          source: describe(source),
          providerName: source.addonName,
          headers: source.proxyHeaders,
          subtitles: source.subtitles.isEmpty
              ? null
              : [
                  for (final sub in source.subtitles)
                    SubtitleFile(url: sub.url, label: sub.label, lang: sub.lang),
                ],
        ),
      );
    }
    return out;
  }

  /// Label shown in the player's Sources list.
  String describe(AddonStreamSource source) {
    final parts = <String>[
      source.qualityLabel,
      if (source.isHdr) 'HDR',
      if (source.isTorrent) 'Torrent',
      if (source.isCachedDebrid) 'Cached',
      if (source.sizeLabel != null) source.sizeLabel!,
      if (source.seeders != null) '${source.seeders} seeds',
    ];
    return parts.join(' · ');
  }

  /// Stable per-episode url the player uses for history and resume.
  String videoUrlFor({required String contentId, String? videoId}) =>
      videoId != null && videoId.isNotEmpty ? videoId : contentId;

  /// Episode wrapper carrying the add-on's own video id, so history entries
  /// line up with what the add-on will be asked for next time.
  Episode? episodeFor(Episode? episode, String? videoId) {
    if (episode == null) return null;
    if (videoId == null || videoId.isEmpty) return episode;
    return Episode(
      name: episode.name,
      url: videoId,
      season: episode.season,
      episode: episode.episode,
      description: episode.description,
      posterUrl: episode.posterUrl,
      airDate: episode.airDate,
    );
  }

  /// Debug helper: a compact JSON view of what will be handed to the player.
  String debugDump(List<StreamResult> streams) => jsonEncode([
    for (final stream in streams)
      {'source': stream.source, 'provider': stream.providerName},
  ]);
}
