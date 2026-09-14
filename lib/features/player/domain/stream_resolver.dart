/// Turning a `PlayerRouteExtra` into something an engine can actually open.
///
/// `PlayerRouteExtra.videoUrl` is not a URL. It is an opaque token handed to
/// the active plugin's `loadStreams()`, and plugins are free to put anything
/// in it — an episode page, a `tmdb:` id, or a JSON array of candidate
/// sources — so it must never be handed to `Uri.parse`.
///
/// Resolution is engine-agnostic: it ends at a [StreamResult] and nothing here
/// knows which engine opens it, so both players share this.
library;

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart'
    show ProviderListenable;
import 'package:http/http.dart' as http;

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/providers.dart';
import '../../../core/storage/history_repository.dart';
import '../../../core/network/http_defaults.dart';
import '../../../core/utils/app_utils.dart';
import '../../../core/utils/stream_quality_sorter.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../library/presentation/history_provider.dart';
import '../../settings/presentation/player_settings_provider.dart';

/// Just enough of Riverpod to read providers. Both `Ref.read` and
/// `WidgetRef.read` satisfy this, so the resolver can be called from a
/// Notifier or straight from a widget without caring which it got.
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// A resolved, ordered candidate list plus the one to open first.
class ResolvedPlayback {
  const ResolvedPlayback({
    required this.streams,
    required this.index,
    this.qualityFilteredFallback = false,
  });

  /// Quality-filtered and sorted, best first. Never empty.
  final List<StreamResult> streams;

  /// Index into [streams] of the stream to play. Later indices are the
  /// failover order.
  final int index;

  /// The quality filter matched nothing and was dropped, so [streams] is
  /// unfiltered. Callers may want to say so.
  final bool qualityFilteredFallback;

  StreamResult get selected => streams[index];
}

/// The identity a stream must present on the network.
///
/// Shared so that every request about one stream looks like the same client.
/// A CDN that ties a signed URL to the requesting agent will 403 if the probe,
/// the licence fetch and the engine disagree — and libVLC's own default
/// User-Agent is rejected outright by many of them.
Map<String, String> playbackHeaders(StreamResult stream) {
  final headers = <String, String>{...?stream.headers};
  final hasUserAgent = headers.keys.any((k) => k.toLowerCase() == 'user-agent');
  if (!hasUserAgent) headers['User-Agent'] = kDefaultBrowserUserAgent;
  return headers;
}

/// Turns a resolved candidate into a URL an engine can actually open.
///
/// Only torrents need work: the torrent service downloads and seeds a
/// `magnet:` link or a `.torrent`, then serves it over loopback HTTP, and the
/// engine plays that. The loopback hop means no headers are involved.
///
/// Returns null when the torrent could not be prepared, which the caller
/// should surface rather than pass to the engine.
Future<String?> playableUrlFor({
  required ProviderReader read,
  required StreamResult stream,
}) async {
  if (isTorrentSource(stream)) {
    return read(torrentServiceProvider).getStreamUrl(stream.url);
  }
  return AppUtils.normalizeUrl(stream.url);
}

/// Whether this candidate has to go through the torrent service first.
///
/// The path check is deliberately narrowed by [StreamResult.source]: a bare
/// absolute path is normally a local file, and only a torrent-sourced one is a
/// seeded file the service already knows about.
bool isTorrentSource(StreamResult stream) =>
    stream.url.startsWith('magnet:') ||
    stream.url.endsWith('.torrent') ||
    (stream.url.startsWith('/') && stream.source.contains('Torrent'));

/// A URL that names itself as on-demand. Vetoes [_liveUrlShapes], because those
/// are guesses and this is the source saying what it is: Xtream Codes serves
/// VOD from `/movie/` and `/series/`, and Wowza's on-demand HLS lives under
/// `/vod/` while still being cut into `chunklist_*.m3u8` files.
final RegExp _vodMarkers = RegExp(r'/(vod|movies?|series)/');

/// URL shapes that in practice only IPTV and live packagers produce.
///
/// Deliberately narrower than "ends in .m3u8" — a VOD HLS ladder is also
/// `.m3u8`, and calling those live would kill seeking and resume across a large
/// slice of ordinary content. So: the path segments IPTV portals mount channels
/// under, the two live-edge playlist names (`stream.m3u8` from most origins,
/// `chunklist` from Wowza), and the Xtream Codes query that asks for a channel
/// list rather than a file.
final RegExp _liveUrlShapes = RegExp(
  r'/live/|/iptv/|stream\.m3u8|chunklist|(type|output)=m3u8',
);

/// Whether this source should be treated as live.
///
/// The item's own content type wins, then the URL scheme, then the URL's
/// shape. Torrents and local files are always VOD however they are labelled.
/// Decided from data both engines can see rather than from an engine report,
/// because liveness changes buffering, seeking, progress writing and what
/// end-of-media means.
///
/// The URL-shape pass matters because plugins routinely hand back an IPTV feed
/// typed as `movie`. Without it that stream gets VOD caching instead of
/// `:live-caching`, writes progress against a duration that means nothing, and
/// on a drop takes the end-of-media branch instead of reconnecting.
bool isLiveSource(MultimediaItem item, String url) {
  if (url.isEmpty) return item.contentType == MultimediaContentType.livestream;
  final lower = url.toLowerCase();
  if (lower.startsWith('magnet:') ||
      lower.endsWith('.torrent') ||
      lower.startsWith('/')) {
    return false;
  }
  if (item.contentType == MultimediaContentType.livestream) return true;
  if (lower.startsWith('rtmp://') ||
      lower.startsWith('rtsp://') ||
      lower.startsWith('mms://') ||
      lower.startsWith('udp://') ||
      lower.startsWith('rtp://')) {
    return true;
  }
  if (_vodMarkers.hasMatch(lower)) return false;
  return _liveUrlShapes.hasMatch(lower);
}

/// Why resolution gave up, as a code the UI can localize.
///
/// Resolution runs with no BuildContext, so it names the failure and
/// [describeStreamFailure] renders it.
enum StreamResolutionFailure {
  noProvider,
  nothingToPlay,
  loadFailed,
  cancelled,
  noStreams,
}

/// Resolution failed in a way worth showing the user.
class StreamResolutionException implements Exception {
  const StreamResolutionException(this.failure, {this.detail});

  final StreamResolutionFailure failure;

  /// The underlying error text, when there is one worth passing on.
  final String? detail;

  /// The developer-facing form, for logs and `toString()`. Derived from
  /// [failure] so a diagnostic can never describe a different failure from the
  /// one the viewer is shown. English on purpose; [describeStreamFailure] is
  /// what the viewer sees.
  String get message => switch (failure) {
    StreamResolutionFailure.noProvider => 'No provider selected.',
    StreamResolutionFailure.nothingToPlay => 'Nothing to play.',
    StreamResolutionFailure.loadFailed => 'Could not load sources: $detail',
    StreamResolutionFailure.cancelled => 'Cancelled.',
    StreamResolutionFailure.noStreams => 'No streams found.',
  };

  @override
  String toString() => message;
}

/// The viewer-facing wording for a failed resolution.
String describeStreamFailure(
  AppLocalizations l10n,
  StreamResolutionException failure,
) => switch (failure.failure) {
  StreamResolutionFailure.noProvider => l10n.playerNoProviderSelected,
  StreamResolutionFailure.nothingToPlay => l10n.playerNothingToPlay,
  StreamResolutionFailure.loadFailed => l10n.playerCouldNotLoadSources(
    failure.detail ?? '',
  ),
  StreamResolutionFailure.cancelled => l10n.playerResolutionCancelled,
  StreamResolutionFailure.noStreams => l10n.playerNoStreamsFound,
};

/// Where one candidate's health probe has got to.
///
/// [trying] is reported when the probe is dispatched rather than when it
/// answers, because the probes run as a parallel race.
enum ProbeOutcome { trying, healthy, unhealthy }

/// Resolves [videoUrl] for [item] into playable streams.
///
/// [preloadedStreams] short-circuits the plugin call, for callers that have
/// already aggregated sources across plugins. It is taken as given — neither
/// re-sorted, re-filtered nor overridden by watch history — so its first entry
/// is what opens.
///
/// [probeCandidates] health-checks that many of the top candidates in parallel
/// and returns the first healthy one, so a dead link fails over before the
/// engine spins on a connect timeout. Pass 0 to skip probing.
///
/// [onCandidates] fires as soon as the ordered list exists; indices in every
/// later report and in [ResolvedPlayback] are indices into that list.
/// [onProbe] fires for each candidate as it is dispatched and again as it
/// settles. Neither changes what is resolved.
///
/// Completing [stopProbing] ends the race early with the best answer the
/// probes have produced, or the preferred candidate when they have produced
/// none. Distinct from [isCancelled], which abandons resolution altogether.
Future<ResolvedPlayback> resolvePlayback({
  required ProviderReader read,
  required MultimediaItem item,
  required String videoUrl,
  List<StreamResult>? preloadedStreams,
  int probeCandidates = 3,
  bool Function()? isCancelled,
  void Function(List<StreamResult> streams)? onCandidates,
  void Function(int index, ProbeOutcome outcome)? onProbe,
  Future<void>? stopProbing,
}) async {
  final direct = _directStream(item, videoUrl);
  if (direct != null) {
    final streams = [direct];
    onCandidates?.call(streams);
    return ResolvedPlayback(streams: streams, index: 0);
  }

  final preloaded = preloadedStreams ?? const <StreamResult>[];
  final provider = _resolveProvider(read, item);
  if (provider == null && preloaded.isEmpty) {
    throw const StreamResolutionException(StreamResolutionFailure.noProvider);
  }
  if (videoUrl.isEmpty && preloaded.isEmpty) {
    throw const StreamResolutionException(
      StreamResolutionFailure.nothingToPlay,
    );
  }

  // A list handed in is a choice the viewer already made: the sheets put the
  // tapped source first and have ranked the rest themselves.
  final handPicked = preloaded.isNotEmpty;

  List<StreamResult> raw;
  if (handPicked) {
    raw = preloaded;
  } else {
    try {
      raw = await provider!.loadStreams(videoUrl);
    } catch (e) {
      throw StreamResolutionException(
        StreamResolutionFailure.loadFailed,
        detail: '$e',
      );
    }
  }
  if (isCancelled?.call() ?? false) {
    throw const StreamResolutionException(StreamResolutionFailure.cancelled);
  }
  if (raw.isEmpty) {
    throw const StreamResolutionException(StreamResolutionFailure.noStreams);
  }

  // Ranking that list again opens a source nobody picked, and a filter can
  // drop the picked one out of it altogether.
  var didFallback = false;
  final settings = await _playerSettings(read);
  final streams = handPicked || settings == null
      ? raw
      : await _byQuality(raw, settings, (v) => didFallback = v);
  if (streams.isEmpty) {
    throw const StreamResolutionException(StreamResolutionFailure.noStreams);
  }
  onCandidates?.call(streams);

  final saved = handPicked ? 0 : _savedStreamIndex(read, item, streams);
  final index = probeCandidates <= 1
      ? saved
      : await _firstHealthyStream(
          streams,
          startIndex: saved,
          limit: probeCandidates,
          isCancelled: isCancelled,
          onProbe: onProbe,
          stopProbing: stopProbing,
        );

  return ResolvedPlayback(
    streams: streams,
    index: index,
    qualityFilteredFallback: didFallback,
  );
}

/// Local files, remote casts and torrents are already playable and never go
/// through a plugin.
StreamResult? _directStream(MultimediaItem item, String videoUrl) {
  final isTorrent =
      item.provider == 'Torrent' ||
      videoUrl.startsWith('magnet:') ||
      videoUrl.endsWith('.torrent');
  final isDirect =
      item.provider == 'Remote' ||
      item.provider == 'Local' ||
      AppUtils.isLocalFile(videoUrl);

  if (!isTorrent && !isDirect) return null;
  return StreamResult(
    url: videoUrl,
    source: isTorrent ? 'Torrent' : 'Video',
    providerName: item.provider ?? 'Local',
    headers: const {},
  );
}

SkyStreamProvider? _resolveProvider(ProviderReader read, MultimediaItem item) {
  final active = read(activeProviderProvider);
  final wanted = item.provider;
  if (wanted != null) {
    final match = read(extensionManagerProvider.notifier)
        .getAllProviders()
        .firstWhereOrNull((p) => p.packageName == wanted || p.name == wanted);
    if (match != null) return match;
  }
  return active;
}

/// Settings can still be loading when playback starts. Silently skipping the
/// quality preference for that window would make the chosen source depend on
/// how warm the cache was, so wait for it instead.
Future<PlayerSettings?> _playerSettings(ProviderReader read) async {
  final snapshot = read(playerSettingsProvider);
  final data = snapshot.asData;
  if (data != null) return data.value;
  try {
    return await read(playerSettingsProvider.future);
  } catch (_) {
    return null;
  }
}

/// Metered link → mobileQuality, unmetered → wifiQuality. If the filter leaves
/// nothing it is dropped rather than failing playback, and [onFallback] reports
/// that.
///
/// Asked once, when playback is resolved, and deliberately not re-asked on a
/// handover: the candidate order is also what failover walks, and the walk
/// records which indices it has tried, so re-sorting mid-session would make
/// that record point at different sources. A viewer who leaves Wi-Fi keeps the
/// rendition they are watching until something else reopens the media, which
/// is the same answer every other player gives.
Future<List<StreamResult>> _byQuality(
  List<StreamResult> streams,
  PlayerSettings settings,
  void Function(bool) onFallback,
) async {
  final preference = await isOnMeteredNetwork()
      ? settings.mobileQuality
      : settings.wifiQuality;
  final filtered = filterStreamsByQuality(
    streams,
    preference,
    settings.qualityFilterMode,
    onFallback: onFallback,
  );
  return sortStreamsByQuality(filtered, preference);
}

/// The source the user last watched this title on, so switching episodes keeps
/// the working provider instead of re-picking from scratch.
int _savedStreamIndex(
  ProviderReader read,
  MultimediaItem item,
  List<StreamResult> streams,
) {
  try {
    final isSeries =
        item.contentType == MultimediaContentType.series ||
        item.contentType == MultimediaContentType.anime;

    String? lastUrl;
    if (isSeries) {
      lastUrl = read(historyRepositoryProvider).getLastStreamUrl(item.url);
    }
    lastUrl ??= read(
      watchHistoryProvider,
    ).firstWhereOrNull((h) => h.item.url == item.url)?.lastStreamUrl;

    if (lastUrl != null) {
      final found = streams.indexWhere((s) => s.url == lastUrl);
      if (found != -1) return found;
    }
  } catch (e) {
    if (kDebugMode) debugPrint('resolvePlayback: saved stream lookup: $e');
  }
  return 0;
}

/// Probes the top [limit] candidates at once and resolves as soon as the
/// highest-priority healthy one is known — with [0,1,2], a healthy 0 returns
/// immediately rather than waiting on 1 and 2. Falls back to [startIndex] if
/// they all fail, so a wrong probe never blocks playback outright.
Future<int> _firstHealthyStream(
  List<StreamResult> streams, {
  required int startIndex,
  required int limit,
  bool Function()? isCancelled,
  void Function(int index, ProbeOutcome outcome)? onProbe,
  Future<void>? stopProbing,
}) async {
  if (streams.isEmpty) return 0;
  final start = startIndex.clamp(0, streams.length - 1);

  final candidates = <int>[];
  for (var i = 0; i < limit; i++) {
    final idx = (start + i) % streams.length;
    if (!candidates.contains(idx)) candidates.add(idx);
  }
  if (candidates.length <= 1) return start;

  final completer = Completer<int>();
  final results = <int, bool>{};

  /// The best answer the race has actually produced. [start] when it has
  /// produced none, which is the same fallback an all-failed race takes.
  int bestSoFar() {
    for (final c in candidates) {
      if (results[c] ?? false) return c;
    }
    return start;
  }

  void record(int idx, bool healthy) {
    // Reported before the completion guard, so a candidate that answers after
    // the race is over still explains itself rather than staying "trying" on
    // screen forever.
    onProbe?.call(idx, healthy ? ProbeOutcome.healthy : ProbeOutcome.unhealthy);
    if (completer.isCompleted) return;
    results[idx] = healthy;
    for (final c in candidates) {
      if (!results.containsKey(c)) return; // a better one is still in flight
      if (results[c]!) {
        completer.complete(c);
        return;
      }
    }
    completer.complete(start); // everything failed
  }

  // Armed before the probes are dispatched: a skip that has already happened
  // must win the race rather than lose it by a microtask.
  if (stopProbing != null) {
    unawaited(
      stopProbing.then((_) {
        if (!completer.isCompleted) completer.complete(bestSoFar());
      }),
    );
  }

  for (final idx in candidates) {
    onProbe?.call(idx, ProbeOutcome.trying);
    unawaited(
      _isHealthy(
        streams[idx],
      ).then((h) => record(idx, h)).catchError((_) => record(idx, false)),
    );
  }

  final winner = await completer.future;
  if (isCancelled?.call() ?? false) return start;
  return winner;
}

/// HEAD first, then a one-byte ranged GET for servers that reject HEAD.
Future<bool> _isHealthy(StreamResult stream) async {
  if (stream.url.startsWith('magnet:') ||
      stream.url.endsWith('.torrent') ||
      stream.url.startsWith('/')) {
    return true;
  }

  final uri = Uri.tryParse(stream.url);
  if (uri == null || !uri.hasScheme) return false;
  final headers = playbackHeaders(stream);

  try {
    final resp = await http
        .head(uri, headers: headers)
        .timeout(const Duration(seconds: 3));
    if (resp.statusCode < 400) return true;
  } catch (_) {
    // Fall through to the ranged GET.
  }

  final client = http.Client();
  try {
    final request = http.Request('GET', uri);
    request.headers.addAll(headers);
    request.headers.putIfAbsent('Range', () => 'bytes=0-0');
    final resp = await client.send(request).timeout(const Duration(seconds: 3));
    await resp.stream.listen((_) {}).cancel();
    return resp.statusCode < 400 || resp.statusCode == 416;
  } catch (_) {
    return false;
  } finally {
    client.close();
  }
}
