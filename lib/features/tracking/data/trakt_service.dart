import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'tracking_service.dart';
import '../domain/sync_progress_item.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/logger/app_logger.dart';
import '../../../../core/network/dio_client_provider.dart';
import '../../../../core/storage/secure_token_storage.dart';
import '../../../../core/config/sync_config.dart';

part 'trakt_service.g.dart';

class TraktService implements TrackingService {
  final Dio _dio;
  final SecureTokenStorage _storage;
  final DateTime Function() _clock;

  static const String _clientId = SyncConfig.traktClientId;
  static const String _kAccessTokenKey = 'trakt_access_token';
  static const String _kRefreshTokenKey = 'trakt_refresh_token';
  static const String _kExpiresAtKey = 'trakt_token_expires_at';

  /// Trakt's device tokens last 90 days. Refreshing a day early means an
  /// app that is opened at all regularly never presents an expired token,
  /// and a device that has been off for a month still recovers on the first
  /// call because the reactive 401 path below covers what the clock missed.
  static const Duration _refreshSkew = Duration(days: 1);

  /// Trakt requires a redirect_uri on the refresh grant even though the device
  /// flow never used one; this is their documented out-of-band placeholder.
  static const String _oobRedirectUri = 'urn:ietf:wg:oauth:2.0:oob';

  String? _accessToken;
  String? _refreshToken;
  int? _expiresAtMs;
  Future<void>? _initFuture;

  /// Serialises concurrent refreshes. Several tracking writes can be in
  /// flight at once (start, stop, an outbox replay); letting each fire its own
  /// refresh burns the single-use refresh token and logs the user out.
  Future<bool>? _refreshInFlight;

  TraktService(this._dio, this._storage, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    _initFuture = _initToken();
  }

  Future<void> _initToken() async {
    _accessToken = await _storage.read(_kAccessTokenKey);
    _refreshToken = await _storage.read(_kRefreshTokenKey);
    _expiresAtMs = int.tryParse(await _storage.read(_kExpiresAtKey) ?? '');
  }

  Future<void> _ensureInit() async {
    if (_initFuture != null) {
      await _initFuture;
    }
  }

  @override
  String get name => 'Trakt';

  @override
  String get idPrefix => 'trakt';

  @override
  String get mainUrl => 'https://trakt.tv';

  @override
  Future<bool> get isLoggedIn async {
    await _ensureInit();
    return _accessToken != null;
  }

  @override
  Future<bool> login({
    Future<void> Function(String url, String code)? onDeviceCodeGenerated,
    Future<void> Function(String url)? onWebViewRequested,
    bool Function()? isCancelled,
  }) async {
    try {
      talker.debug('TraktService: Initiating Device PIN Flow...');
      final response = await _dio.post<dynamic>(
        'https://api.trakt.tv/oauth/device/code',
        data: {'client_id': _clientId},
      );

      final userCode = response.data['user_code'] as String;
      final deviceCode = response.data['device_code'] as String;
      final verificationUrl = response.data['verification_url'] as String;
      final interval = (response.data['interval'] as num?)?.toInt() ?? 5;

      talker.debug(
        'TRAKT DEVICE LOGIN — go to $verificationUrl and enter code $userCode',
      );

      if (onDeviceCodeGenerated != null) {
        await onDeviceCodeGenerated(verificationUrl, userCode);
      }

      // Polling
      int attempts = 0;
      while (attempts < 60) {
        if (isCancelled != null && isCancelled()) {
          talker.debug('TraktService: Polling cancelled by user.');
          return false;
        }
        await Future<void>.delayed(Duration(seconds: interval));
        if (isCancelled != null && isCancelled()) return false;

        try {
          talker.debug('TraktService: Polling for token...');
          final tokenResponse = await _dio.post<dynamic>(
            'https://api.trakt.tv/oauth/device/token',
            data: {
              'code': deviceCode,
              'client_id': _clientId,
              'client_secret': SyncConfig.traktClientSecret,
            },
          );

          final data = tokenResponse.data;
          if (tokenResponse.statusCode == 200 &&
              data is Map &&
              data['access_token'] != null) {
            await _storeTokens(Map<String, dynamic>.from(data));
            talker.debug('TraktService: Login successful!');
            return true;
          }
        } on DioException catch (e) {
          if (e.response?.statusCode != 400) {
            // 400 = authorization_pending
            talker.debug(
              'TraktService: Polling error: ${e.response?.statusCode} ${e.message}',
            );
            if (e.response?.statusCode == 404 ||
                e.response?.statusCode == 409 ||
                e.response?.statusCode == 410 ||
                e.response?.statusCode == 418) {
              // 404 Not Found, 409 Already Used, 410 Expired, 418 Denied
              talker.debug('TraktService: Terminal error, stopping polling.');
              return false;
            }
          }
        }
        attempts++;
      }
      talker.debug('TraktService: Login timed out.');
      return false;
    } catch (e) {
      talker.error('TraktService: Login failed', e);
      return false;
    }
  }

  /// Persists an access/refresh pair from a token or refresh response.
  ///
  /// The previous implementation kept only `access_token` and threw away
  /// `refresh_token` and `expires_in`, so roughly 90 days after connecting,
  /// every Trakt call started 401-ing with nothing able to recover it and
  /// nothing in the UI saying so.
  Future<void> _storeTokens(Map<String, dynamic> data) async {
    _accessToken = data['access_token'].toString();
    final refresh = data['refresh_token']?.toString();
    if (refresh != null && refresh.isNotEmpty) _refreshToken = refresh;

    final expiresIn = (data['expires_in'] as num?)?.toInt();
    if (expiresIn != null && expiresIn > 0) {
      // Trakt reports `created_at` in whole seconds; trust the server's clock
      // for the origin and fall back to ours when it is absent.
      final createdAt = (data['created_at'] as num?)?.toInt();
      final originMs = createdAt != null
          ? createdAt * 1000
          : _clock().millisecondsSinceEpoch;
      _expiresAtMs = originMs + expiresIn * 1000;
    } else {
      _expiresAtMs = null;
    }

    await _storage.write(_kAccessTokenKey, _accessToken!);
    if (_refreshToken != null) {
      await _storage.write(_kRefreshTokenKey, _refreshToken!);
    }
    if (_expiresAtMs != null) {
      await _storage.write(_kExpiresAtKey, _expiresAtMs!.toString());
    } else {
      await _storage.delete(_kExpiresAtKey);
    }
  }

  /// Drops the session so [isLoggedIn] reports false.
  ///
  /// This is the *visible* half of the fix: the account tile reads
  /// [isLoggedIn], so a dead grant now turns "Connected" back into a connect
  /// prompt instead of leaving the user believing they are still syncing.
  Future<void> _clearSession(String reason) async {
    talker.error('TraktService: clearing the session — $reason');
    _accessToken = null;
    _refreshToken = null;
    _expiresAtMs = null;
    await _storage.delete(_kAccessTokenKey);
    await _storage.delete(_kRefreshTokenKey);
    await _storage.delete(_kExpiresAtKey);
  }

  /// True when there is a usable access token, refreshing first if the stored
  /// one is at or past its expiry.
  Future<bool> _ensureFreshToken() async {
    await _ensureInit();
    if (_accessToken == null) return false;
    final expiresAt = _expiresAtMs;
    // A session stored before expiries were persisted has no deadline to
    // check. Leave it alone; the reactive 401 path below still covers it.
    if (expiresAt == null) return true;
    if (_clock().millisecondsSinceEpoch + _refreshSkew.inMilliseconds <
        expiresAt) {
      return true;
    }
    return _refreshAccessToken();
  }

  /// Serialised refresh, mirroring the pattern in [MalService].
  Future<bool> _refreshAccessToken() {
    final existing = _refreshInFlight;
    if (existing != null) return existing;
    final fut = _doRefreshAccessToken();
    _refreshInFlight = fut;
    fut.whenComplete(() => _refreshInFlight = null);
    return fut;
  }

  Future<bool> _doRefreshAccessToken() async {
    final refresh = _refreshToken;
    if (refresh == null) {
      // Nothing to refresh with — either a pre-refresh-support session or a
      // grant we already cleared. Either way this token cannot be revived.
      await _clearSession('no refresh token stored');
      return false;
    }

    try {
      talker.debug('TraktService: Refreshing access token...');
      final response = await _dio.post<dynamic>(
        'https://api.trakt.tv/oauth/token',
        data: {
          'refresh_token': refresh,
          'client_id': _clientId,
          'client_secret': SyncConfig.traktClientSecret,
          'redirect_uri': _oobRedirectUri,
          'grant_type': 'refresh_token',
        },
      );

      final data = response.data;
      if (response.statusCode == 200 &&
          data is Map &&
          data['access_token'] != null) {
        await _storeTokens(Map<String, dynamic>.from(data));
        talker.debug('TraktService: Token refreshed successfully');
        return true;
      }
      await _clearSession('refresh returned ${response.statusCode}');
      return false;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      // A 4xx is Trakt telling us the grant is dead: revoked, reused or
      // expired. Anything else — no response at all, a timeout, a 5xx — is the
      // network, and logging someone out because their train went into a
      // tunnel would be a worse bug than the one this fixes.
      if (status != null && status >= 400 && status < 500) {
        await _clearSession('refresh rejected with $status');
      } else {
        talker.error('TraktService: Token refresh failed, will retry', e);
      }
      return false;
    } catch (e) {
      talker.error('TraktService: Token refresh failed, will retry', e);
      return false;
    }
  }

  /// Runs an authenticated request, refreshing once on a 401.
  ///
  /// [send] must build its headers from [_authHeaders] at call time so the
  /// retry uses the token the refresh just produced. Returns null when the
  /// call could not be made or did not succeed.
  Future<Response<dynamic>?> _sendAuthorized(
    String label,
    Future<Response<dynamic>> Function() send,
  ) async {
    if (!await _ensureFreshToken()) return null;
    try {
      return await send();
    } on DioException catch (e) {
      if (e.response?.statusCode != 401) {
        talker.error('TraktService: $label failed', e);
        return null;
      }
      // The stored expiry said the token was fine and Trakt disagrees — the
      // grant was revoked, or the clock is wrong. Refresh and try once more.
      if (!await _refreshAccessToken()) return null;
      try {
        return await send();
      } catch (retryError) {
        talker.error('TraktService: $label failed after refresh', retryError);
        return null;
      }
    } catch (e) {
      talker.error('TraktService: $label failed', e);
      return null;
    }
  }

  Map<String, String> get _authHeaders => {
    'Content-Type': 'application/json',
    'trakt-api-version': '2',
    'trakt-api-key': _clientId,
    'Authorization': 'Bearer $_accessToken',
  };

  @override
  Future<void> logout() async {
    talker.debug('TraktService: Logging out...');
    _accessToken = null;
    _refreshToken = null;
    _expiresAtMs = null;
    await _storage.delete(_kAccessTokenKey);
    await _storage.delete(_kRefreshTokenKey);
    await _storage.delete(_kExpiresAtKey);
  }

  @override
  Future<List<MultimediaItem>> search(String query) async {
    if (_accessToken == null) return [];

    // Search implementation
    return [];
  }

  @override
  Future<Map<String, String>> syncIds(MultimediaItem item) async {
    // Trakt uses IMDB and TMDB directly in scrobbling, so we don't strictly need
    // a separate ID resolution unless we want the Trakt slug.
    return {};
  }

  Map<String, dynamic> _buildScrobblePayload(
    MultimediaItem item,
    Episode? episode,
    double progress,
  ) {
    final payload = <String, dynamic>{
      'progress': progress * 100,
      'app_version': '1.0',
      'app_date': '2024-05-26',
    };

    if (item.contentType == MultimediaContentType.movie) {
      payload['movie'] = {
        'ids': {
          if (item.tmdbId != null) 'tmdb': item.tmdbId,
          if (item.imdbId != null) 'imdb': item.imdbId,
        },
      };
    } else {
      payload['show'] = {
        'ids': {
          if (item.tmdbId != null) 'tmdb': item.tmdbId,
          if (item.imdbId != null) 'imdb': item.imdbId,
        },
      };
      if (episode != null) {
        payload['episode'] = {
          'season': episode.season,
          'number': episode.episode,
        };
      }
    }
    return payload;
  }

  Future<bool> _scrobble(
    String action,
    MultimediaItem item,
    Episode? episode,
    double progress,
  ) async {
    await _ensureInit();
    if (_accessToken == null) return false;
    if (item.tmdbId == null && item.imdbId == null) {
      talker.debug('TraktService: Cannot scrobble, no TMDB/IMDB ID available');
      return false;
    }

    final payload = _buildScrobblePayload(item, episode, progress);
    final response = await _sendAuthorized(
      'Scrobble $action',
      () => _dio.post<dynamic>(
        'https://api.trakt.tv/scrobble/$action',
        data: payload,
        options: Options(headers: _authHeaders),
      ),
    );
    if (response == null) return false;
    talker.debug(
      'TraktService: Scrobble $action success: ${response.statusCode}',
    );
    return response.statusCode == 201 || response.statusCode == 200;
  }

  @override
  Future<bool> markWatched(
    MultimediaItem item,
    Episode? episode, {
    Map<String, String>? resolvedIds,
  }) async {
    await _ensureInit();
    if (_accessToken == null) return false;
    if (item.tmdbId == null && item.imdbId == null) return false;

    // We can use scrobble stop with progress >= 85 to mark as watched.
    // Trakt automatically marks it watched if progress >= 80.
    return _scrobble(
      'stop',
      item,
      episode,
      1.0,
    ); // Send 100% to ensure it's marked
  }

  @override
  Future<bool> scrobbleStart(
    MultimediaItem item,
    Episode? episode,
    double progress, {
    Map<String, String>? resolvedIds,
  }) async {
    return _scrobble('start', item, episode, progress);
  }

  @override
  Future<bool> scrobblePause(
    MultimediaItem item,
    Episode? episode,
    double progress, {
    Map<String, String>? resolvedIds,
  }) async {
    return _scrobble('pause', item, episode, progress);
  }

  @override
  Future<bool> scrobbleStop(
    MultimediaItem item,
    Episode? episode,
    double progress, {
    Map<String, String>? resolvedIds,
  }) async {
    return _scrobble('stop', item, episode, progress);
  }

  @override
  Future<bool> addToPlanToWatch(
    MultimediaItem item, {
    Map<String, String>? resolvedIds,
  }) async {
    await _ensureInit();
    if (_accessToken == null) return false;
    if (item.tmdbId == null && item.imdbId == null) return false;

    final payload = <String, dynamic>{};
    final ids = {
      if (item.tmdbId != null) 'tmdb': item.tmdbId,
      if (item.imdbId != null) 'imdb': item.imdbId,
    };
    if (item.contentType == MultimediaContentType.movie) {
      payload['movies'] = [
        {'ids': ids},
      ];
    } else {
      payload['shows'] = [
        {'ids': ids},
      ];
    }

    final response = await _sendAuthorized(
      'Add to watchlist',
      () => _dio.post<dynamic>(
        'https://api.trakt.tv/sync/watchlist',
        data: payload,
        options: Options(headers: _authHeaders),
      ),
    );
    if (response == null) return false;
    talker.debug('TraktService: Added to watchlist: ${response.statusCode}');
    return response.statusCode == 201 || response.statusCode == 200;
  }

  @override
  Future<List<SyncProgressItem>> pullPlaybackProgress() async {
    await _ensureInit();
    if (_accessToken == null) return [];

    final response = await _sendAuthorized(
      'Pull playback progress',
      () => _dio.get<dynamic>(
        'https://api.trakt.tv/sync/playback',
        options: Options(headers: _authHeaders),
      ),
    );

    if (response != null &&
        response.statusCode == 200 &&
        response.data is List) {
      try {
        final items = response.data as List;
        return items
            .map(
              (json) => SyncProgressItem.fromJson(json as Map<String, dynamic>),
            )
            .toList();
      } catch (e) {
        talker.error('TraktService: Pull playback progress unparseable', e);
      }
    }
    return [];
  }

  @override
  Future<bool> removePlaybackProgress(String id) async {
    await _ensureInit();
    if (_accessToken == null) return false;
    final response = await _sendAuthorized(
      'Remove playback progress',
      () => _dio.delete<dynamic>(
        'https://api.trakt.tv/sync/playback/$id',
        options: Options(headers: _authHeaders),
      ),
    );
    return response?.statusCode == 204;
  }
}

@riverpod
TraktService traktService(Ref ref) {
  return TraktService(
    ref.watch(dioClientProvider),
    ref.watch(secureTokenStorageProvider),
  );
}
