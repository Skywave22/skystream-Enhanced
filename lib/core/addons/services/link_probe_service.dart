import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../network/dio_client_provider.dart';
import '../../utils/file_size_formatter.dart';

part 'link_probe_service.g.dart';

@Riverpod(keepAlive: true)
LinkProbeService linkProbeService(Ref ref) =>
    LinkProbeService(ref.watch(dioClientProvider));

/// One rendition advertised inside an HLS master playlist.
class HlsVariant {
  final int? height;
  final int? bandwidth;
  const HlsVariant({this.height, this.bandwidth});

  String get label => height != null ? '${height}p' : 'auto';
}

/// Outcome of testing whether a link is actually usable.
class LinkProbeResult {
  final bool reachable;
  final int? statusCode;
  final int? contentLength;
  final String? contentType;
  final bool supportsRanges;
  final List<HlsVariant> variants;
  final String? failureReason;

  const LinkProbeResult({
    required this.reachable,
    this.statusCode,
    this.contentLength,
    this.contentType,
    this.supportsRanges = false,
    this.variants = const [],
    this.failureReason,
  });

  static const LinkProbeResult pending = LinkProbeResult(reachable: false);

  bool get isVideo {
    final type = contentType?.toLowerCase() ?? '';
    return type.startsWith('video/') ||
        type.contains('mpegurl') ||
        type.contains('matroska') ||
        type.contains('dash+xml') ||
        type.contains('octet-stream');
  }

  /// Resumable downloads need byte ranges; without them the downloader can
  /// still work but cannot chunk or resume, which is worth surfacing.
  bool get isDownloadable => reachable && (contentLength ?? 0) > 0;

  String? get sizeLabel {
    final length = contentLength;
    if (length == null || length <= 0) return null;
    return formatFileSize(length, fractionDigits: 1);
  }

  /// Best resolution the link itself advertises (HLS master playlists only).
  String? get resolutionLabel {
    if (variants.isEmpty) return null;
    final heights = variants
        .map((v) => v.height ?? 0)
        .where((h) => h > 0)
        .toList();
    if (heights.isEmpty) return null;
    heights.sort();
    final best = heights.last;
    if (best >= 2160) return '4K';
    if (best >= 1440) return '2K';
    return '${best}p';
  }
}

/// Verifies that a link is alive before the user commits to it.
///
/// Used by the sources sheet to tag rows as working/dead, to show the real
/// file size, and to read the true resolution out of HLS master playlists
/// instead of trusting the plugin's label.
class LinkProbeService {
  LinkProbeService(this._dio);

  final Dio _dio;
  final Map<String, LinkProbeResult> _cache = {};
  final Map<String, Future<LinkProbeResult>> _inFlight = {};

  static const Duration _timeout = Duration(seconds: 8);
  static final RegExp _resolutionRe = RegExp(r'RESOLUTION=(\d+)x(\d+)');
  static final RegExp _bandwidthRe = RegExp(r'BANDWIDTH=(\d+)');

  LinkProbeResult? cached(String url) => _cache[url];

  Future<LinkProbeResult> probe(
    String url, {
    Map<String, String>? headers,
  }) async {
    final cachedResult = _cache[url];
    if (cachedResult != null) return cachedResult;

    final pending = _inFlight[url];
    if (pending != null) return pending;

    final future = _probe(url, headers);
    _inFlight[url] = future;
    try {
      final result = await future;
      _cache[url] = result;
      return result;
    } finally {
      _inFlight.remove(url);
    }
  }

  /// Probes many links with a bounded worker pool so a 40-source list doesn't
  /// open 40 sockets at once.
  Future<void> probeAll(
    List<String> urls, {
    Map<String, Map<String, String>?> headers = const {},
    int concurrency = 4,
    void Function(String url, LinkProbeResult result)? onResult,
  }) async {
    final queue = List<String>.of(urls);
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final url = queue.removeAt(0);
        final result = await probe(url, headers: headers[url]);
        onResult?.call(url, result);
      }
    }

    final workers = List.generate(
      queue.length < concurrency ? queue.length : concurrency,
      (_) => worker(),
    );
    await Future.wait(workers);
  }

  Future<LinkProbeResult> _probe(
    String url,
    Map<String, String>? headers,
  ) async {
    if (url.startsWith('magnet:') || url.startsWith('/')) {
      // Torrents can't be HEAD-checked; treat as "unknown but usable".
      return const LinkProbeResult(reachable: true, supportsRanges: true);
    }

    try {
      final response = await _dio.head<void>(
        url,
        options: Options(
          headers: headers,
          followRedirects: true,
          receiveTimeout: _timeout,
          sendTimeout: _timeout,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      final result = _fromHeaders(response.statusCode, response.headers.map);
      if (result.reachable) {
        return _maybeWithHlsVariants(url, headers, result);
      }
    } catch (error) {
      if (kDebugMode) debugPrint('[LinkProbe] HEAD failed for $url: $error');
    }

    // Many CDNs reject HEAD outright — retry with a 1-byte ranged GET, which
    // is both cheap and a stronger signal (it proves range support too).
    try {
      final response = await _dio.get<List<int>>(
        url,
        options: Options(
          headers: {...?headers, 'Range': 'bytes=0-1'},
          responseType: ResponseType.bytes,
          followRedirects: true,
          receiveTimeout: _timeout,
          sendTimeout: _timeout,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      final result = _fromHeaders(
        response.statusCode,
        response.headers.map,
        rangedGet: true,
      );
      if (result.reachable) {
        return _maybeWithHlsVariants(url, headers, result);
      }
      return result;
    } catch (error) {
      return LinkProbeResult(
        reachable: false,
        failureReason: error is DioException
            ? (error.message ?? error.type.name)
            : error.toString(),
      );
    }
  }

  LinkProbeResult _fromHeaders(
    int? statusCode,
    Map<String, List<String>> headers, {
    bool rangedGet = false,
  }) {
    String? headerValue(String name) {
      final values = headers[name] ?? headers[name.toLowerCase()];
      if (values == null || values.isEmpty) return null;
      return values.first;
    }

    final ok = statusCode != null && statusCode >= 200 && statusCode < 400;
    final contentRange = headerValue('content-range');
    int? length = int.tryParse(headerValue('content-length') ?? '');
    if (rangedGet && contentRange != null) {
      final total = contentRange.split('/').last;
      length = int.tryParse(total) ?? length;
    }

    return LinkProbeResult(
      reachable: ok,
      statusCode: statusCode,
      contentLength: length,
      contentType: headerValue('content-type'),
      supportsRanges:
          (headerValue('accept-ranges')?.contains('bytes') ?? false) ||
          statusCode == 206,
      failureReason: ok ? null : 'HTTP $statusCode',
    );
  }

  Future<LinkProbeResult> _maybeWithHlsVariants(
    String url,
    Map<String, String>? headers,
    LinkProbeResult base,
  ) async {
    final looksHls =
        url.toLowerCase().contains('.m3u8') ||
        (base.contentType?.toLowerCase().contains('mpegurl') ?? false);
    if (!looksHls) return base;

    try {
      final response = await _dio.get<String>(
        url,
        options: Options(
          headers: headers,
          responseType: ResponseType.plain,
          receiveTimeout: _timeout,
          sendTimeout: _timeout,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      final body = response.data ?? '';
      final variants = <HlsVariant>[];
      for (final line in body.split('\n')) {
        if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
        final res = _resolutionRe.firstMatch(line);
        final bandwidth = _bandwidthRe.firstMatch(line);
        variants.add(
          HlsVariant(
            height: res == null ? null : int.tryParse(res.group(2)!),
            bandwidth: bandwidth == null
                ? null
                : int.tryParse(bandwidth.group(1)!),
          ),
        );
      }
      if (variants.isEmpty) return base;
      return LinkProbeResult(
        reachable: base.reachable,
        statusCode: base.statusCode,
        contentLength: base.contentLength,
        contentType: base.contentType,
        supportsRanges: base.supportsRanges,
        variants: variants,
      );
    } catch (_) {
      return base;
    }
  }

  void clear() {
    _cache.clear();
  }
}
