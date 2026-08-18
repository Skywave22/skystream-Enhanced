import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/addon_stream.dart';
import '../models/stremio_addon.dart';
import 'addon_client.dart';

part 'addon_subtitle_service.g.dart';

@Riverpod(keepAlive: true)
AddonSubtitleService addonSubtitleService(Ref ref) =>
    AddonSubtitleService(ref.watch(addonClientProvider));

/// Pulls subtitles from every add-on that implements the `subtitles` resource
/// (OpenSubtitles v3 and friends) and merges them with whatever the chosen
/// stream already carried.
///
/// Add-on only: the plugin subtitle providers are a separate system used by the
/// original player.
class AddonSubtitleService {
  AddonSubtitleService(this._client);

  final AddonClient _client;

  static const Duration _timeout = Duration(seconds: 12);

  Future<List<AddonSubtitle>> fetch({
    required List<InstalledAddon> addons,
    required String type,
    required List<String> ids,
    int? videoSize,
    String? filename,
  }) async {
    final targets = addons
        .where((a) => a.manifest.hasResource('subtitles'))
        .toList();
    if (targets.isEmpty || ids.isEmpty) return const [];

    final extra = <String, String>{
      if (videoSize != null && videoSize > 0) 'videoSize': '$videoSize',
      if (filename != null && filename.isNotEmpty) 'filename': filename,
    };

    Future<List<AddonSubtitle>> ask(InstalledAddon addon, String id) async {
      try {
        return await _client
            .subtitles(
              addon,
              type: type,
              id: id,
              extra: extra.isEmpty ? null : extra,
            )
            .timeout(_timeout);
      } catch (_) {
        return const <AddonSubtitle>[];
      }
    }

    // Only the first id that produces anything is used, exactly like stream
    // resolution, so a fallback id never doubles the list.
    for (final id in ids) {
      final results = await Future.wait([
        for (final addon in targets) ask(addon, id),
      ]);

      final seen = <String>{};
      final out = <AddonSubtitle>[];
      for (final list in results) {
        for (final sub in list) {
          if (seen.add(sub.url)) out.add(sub);
        }
      }
      if (out.isNotEmpty) {
        out.sort((a, b) => a.lang.toLowerCase().compareTo(b.lang.toLowerCase()));
        return out;
      }
    }
    return const [];
  }
}

/// Maps the ISO-ish language codes add-ons use onto readable names.
String prettySubtitleLanguage(String code) {
  const names = <String, String>{
    'eng': 'English',
    'en': 'English',
    'spa': 'Spanish',
    'es': 'Spanish',
    'fre': 'French',
    'fra': 'French',
    'fr': 'French',
    'ger': 'German',
    'deu': 'German',
    'de': 'German',
    'ita': 'Italian',
    'it': 'Italian',
    'por': 'Portuguese',
    'pt': 'Portuguese',
    'rus': 'Russian',
    'ru': 'Russian',
    'ara': 'Arabic',
    'ar': 'Arabic',
    'hin': 'Hindi',
    'hi': 'Hindi',
    'urd': 'Urdu',
    'ur': 'Urdu',
    'ben': 'Bengali',
    'tur': 'Turkish',
    'tr': 'Turkish',
    'jpn': 'Japanese',
    'ja': 'Japanese',
    'kor': 'Korean',
    'ko': 'Korean',
    'chi': 'Chinese',
    'zho': 'Chinese',
    'zh': 'Chinese',
    'nld': 'Dutch',
    'dut': 'Dutch',
    'pol': 'Polish',
    'swe': 'Swedish',
    'dan': 'Danish',
    'fin': 'Finnish',
    'nor': 'Norwegian',
    'ell': 'Greek',
    'gre': 'Greek',
    'heb': 'Hebrew',
    'ind': 'Indonesian',
    'tha': 'Thai',
    'vie': 'Vietnamese',
    'ukr': 'Ukrainian',
    'ces': 'Czech',
    'cze': 'Czech',
    'ron': 'Romanian',
    'rum': 'Romanian',
    'hun': 'Hungarian',
    'tam': 'Tamil',
    'tel': 'Telugu',
    'mal': 'Malayalam',
    'mar': 'Marathi',
    'fas': 'Persian',
    'per': 'Persian',
  };
  final key = code.trim().toLowerCase();
  final name = names[key];
  if (name != null) return name;
  if (key.isEmpty) return 'Unknown';
  return key[0].toUpperCase() + key.substring(1);
}
