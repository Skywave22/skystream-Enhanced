import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'doh_service.dart';
import 'http_defaults.dart';

part 'dio_client_provider.g.dart';

@riverpod
Dio dioClient(Ref ref) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      // Default to a real browser UA so resolution presents the same
      // identity the player will use during playback. Per-request headers
      // from plugins still override this. See http_defaults.dart.
      headers: const {'User-Agent': kDefaultBrowserUserAgent},
    ),
  );

  // Instead of an interceptor (which mangles the URL/Host headers for HTTPS/SNI),
  // we intercept at the socket level. This intercepts socket creation right
  // before the TLS handshake, preserving the original URI host for SNI verification.
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      client.idleTimeout = const Duration(minutes: 5);
      client.maxConnectionsPerHost = 10;
      client
          .connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) async {
        final host = uri.host;

        // Helper to upgrade the socket to TLS if the scheme is https
        Future<ConnectionTask<Socket>> connectWithTlsUpgrade(
          Future<ConnectionTask<Socket>> taskFuture,
        ) {
          if (uri.scheme == 'https') {
            return taskFuture.then((task) {
              return ConnectionTask.fromSocket(
                task.socket.then((socket) {
                  return SecureSocket.secure(socket, host: uri.host);
                }),
                task.cancel,
              );
            });
          }
          return taskFuture;
        }

        // Optionally skip if DoH is disabled
        if (!DohService.instance.enabled) {
          return connectWithTlsUpgrade(
            Socket.startConnect(
              host,
              uri.port,
            ).timeout(const Duration(seconds: 10)),
          );
        }

        final ip = await DohService.instance
            .resolve(host)
            .timeout(const Duration(seconds: 15), onTimeout: () => null);
        if (ip != null) {
          if (kDebugMode) {
            debugPrint(
              '[IOHttpClientAdapter] Connecting $host via DoH resolved IP: $ip',
            );
          }
          // Connect to the resolved IP but preserve the original uri properties for SNI
          return connectWithTlsUpgrade(
            Socket.startConnect(
              ip,
              uri.port,
            ).timeout(const Duration(seconds: 10)),
          );
        }

        // Fallback to normal DNS
        return connectWithTlsUpgrade(
          Socket.startConnect(
            host,
            uri.port,
          ).timeout(const Duration(seconds: 10)),
        );
      };
      return client;
    },
  );

  // Metadata GETs are pure and repeat constantly while browsing (Explore ->
  // details -> back). A tiny in-memory TTL cache in front of them removes the
  // biggest source of perceived latency without touching any call site.
  dio.interceptors.add(MetadataCacheInterceptor());

  return dio;
}

/// In-memory response cache for read-only metadata APIs.
///
/// Only GETs to a small allow-list of metadata hosts are cached, for a short
/// TTL, so stream resolution and plugin traffic are never affected.
class MetadataCacheInterceptor extends Interceptor {
  MetadataCacheInterceptor({
    this.ttl = const Duration(minutes: 10),
    this.maxEntries = 200,
  });

  final Duration ttl;
  final int maxEntries;

  static const Set<String> _cacheableHosts = {
    'api.themoviedb.org',
    'graphql.anilist.co',
    'v3-cinemeta.strem.io',
  };

  final Map<String, _CachedResponse> _entries = {};

  bool _isCacheable(RequestOptions options) {
    if (options.method.toUpperCase() != 'GET') return false;
    return _cacheableHosts.contains(options.uri.host);
  }

  String _keyFor(RequestOptions options) => options.uri.toString();

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) {
    if (!_isCacheable(options)) return handler.next(options);

    final key = _keyFor(options);
    final cached = _entries[key];
    if (cached != null && cached.expiresAt.isAfter(DateTime.now())) {
      return handler.resolve(
        Response<dynamic>(
          requestOptions: options,
          data: cached.data,
          statusCode: 200,
          extra: const {'fromMetadataCache': true},
        ),
      );
    }
    if (cached != null) _entries.remove(key);
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final options = response.requestOptions;
    if (_isCacheable(options) &&
        response.statusCode == 200 &&
        response.data != null) {
      if (_entries.length >= maxEntries) {
        final stale = _entries.keys.take(maxEntries ~/ 4).toList();
        for (final key in stale) {
          _entries.remove(key);
        }
      }
      _entries[_keyFor(options)] = _CachedResponse(
        response.data,
        DateTime.now().add(ttl),
      );
    }
    handler.next(response);
  }

  void clear() => _entries.clear();
}

class _CachedResponse {
  final dynamic data;
  final DateTime expiresAt;
  const _CachedResponse(this.data, this.expiresAt);
}
