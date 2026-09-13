import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/storage/secure_token_storage.dart';
import 'package:skystream/features/tracking/data/trakt_service.dart';

/// Trakt device tokens expire after ~90 days. Before this suite the service
/// stored only `access_token`, so on day 91 every call 401'd, nothing could
/// renew it, and the account tile still read "Connected" forever.
///
/// Everything here is asserted against the wire: which requests the service
/// makes, in what order, and with which bearer token.
class _FakeTokenStorage implements SecureTokenStorage {
  _FakeTokenStorage([Map<String, String>? seed]) : values = {...?seed};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

/// A response, or a throw, for one request.
typedef _Reply = ResponseBody Function(RequestOptions options);

class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.reply);

  _Reply reply;

  final List<RequestOptions> requests = <RequestOptions>[];

  List<String> get paths => requests.map((r) => r.path).toList();

  String? bearerAt(int index) =>
      requests[index].headers['Authorization'] as String?;

  Map<String, dynamic> bodyAt(int index) =>
      Map<String, dynamic>.from(requests[index].data as Map);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return reply(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Map<String, dynamic> body, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

const String _tokenUrl = '/oauth/token';

void main() {
  late _ScriptedAdapter adapter;
  late Dio dio;

  const accessKey = 'trakt_access_token';
  const refreshKey = 'trakt_refresh_token';
  const expiryKey = 'trakt_token_expires_at';

  final now = DateTime.utc(2026, 9, 12, 12);
  DateTime clock() => now;

  final item = MultimediaItem(
    title: 'Show',
    url: 'https://example.com/show',
    posterUrl: '',
    contentType: MultimediaContentType.series,
    tmdbId: 1399,
  );
  final episode = Episode(name: 'E1', url: 'e1', season: 1, episode: 1);

  /// A session that expired yesterday — the state a real user is in three
  /// months after connecting.
  Map<String, String> expiredSession() => {
    accessKey: 'stale-access',
    refreshKey: 'good-refresh',
    expiryKey: now
        .subtract(const Duration(days: 1))
        .millisecondsSinceEpoch
        .toString(),
  };

  /// A session with two months left on it.
  Map<String, String> liveSession() => {
    accessKey: 'live-access',
    refreshKey: 'good-refresh',
    expiryKey: now
        .add(const Duration(days: 60))
        .millisecondsSinceEpoch
        .toString(),
  };

  Map<String, dynamic> refreshedTokens() => {
    'access_token': 'fresh-access',
    'refresh_token': 'fresh-refresh',
    'expires_in': 7776000,
    'created_at': now.millisecondsSinceEpoch ~/ 1000,
  };

  setUp(() {
    adapter = _ScriptedAdapter((_) => _json(const {}));
    dio = Dio()..httpClientAdapter = adapter;
  });

  TraktService serviceWith(Map<String, String> seed, _FakeTokenStorage store) {
    store.values
      ..clear()
      ..addAll(seed);
    return TraktService(dio, store, clock: clock);
  }

  group('proactive refresh', () {
    test(
      'an expired token is refreshed before the write, and the write carries '
      'the new bearer',
      () async {
        final store = _FakeTokenStorage();
        final service = serviceWith(expiredSession(), store);

        adapter.reply = (options) {
          if (options.path.endsWith(_tokenUrl)) {
            return _json(refreshedTokens());
          }
          // The old token must never reach a write. If it does, Trakt 401s and
          // the mark is lost — which is the bug.
          if (options.headers['Authorization'] == 'Bearer stale-access') {
            return _json(const {'error': 'unauthorized'}, status: 401);
          }
          return _json(const {'action': 'scrobble'}, status: 201);
        };

        final ok = await service.markWatched(item, episode);

        expect(ok, isTrue);
        expect(adapter.paths, [
          'https://api.trakt.tv/oauth/token',
          'https://api.trakt.tv/scrobble/stop',
        ]);
        expect(adapter.bodyAt(0)['grant_type'], 'refresh_token');
        expect(adapter.bodyAt(0)['refresh_token'], 'good-refresh');
        expect(adapter.bearerAt(1), 'Bearer fresh-access');
      },
    );

    test('the refreshed pair and its new expiry are persisted', () async {
      final store = _FakeTokenStorage();
      final service = serviceWith(expiredSession(), store);

      adapter.reply = (options) => options.path.endsWith(_tokenUrl)
          ? _json(refreshedTokens())
          : _json(const {}, status: 201);

      await service.markWatched(item, episode);

      expect(store.values[accessKey], 'fresh-access');
      expect(store.values[refreshKey], 'fresh-refresh');
      expect(
        int.parse(store.values[expiryKey]!),
        now.add(const Duration(seconds: 7776000)).millisecondsSinceEpoch,
      );
    });

    test('a token with time left on it is used as-is', () async {
      final store = _FakeTokenStorage();
      final service = serviceWith(liveSession(), store);

      adapter.reply = (_) => _json(const {}, status: 201);

      await service.markWatched(item, episode);

      expect(adapter.paths, ['https://api.trakt.tv/scrobble/stop']);
      expect(adapter.bearerAt(0), 'Bearer live-access');
    });
  });

  group('reactive refresh', () {
    test('a 401 on the write triggers one refresh and one retry', () async {
      final store = _FakeTokenStorage();
      final service = serviceWith(liveSession(), store);

      adapter.reply = (options) {
        if (options.path.endsWith(_tokenUrl)) return _json(refreshedTokens());
        if (options.headers['Authorization'] == 'Bearer live-access') {
          return _json(const {'error': 'unauthorized'}, status: 401);
        }
        return _json(const {}, status: 201);
      };

      final ok = await service.markWatched(item, episode);

      expect(ok, isTrue);
      expect(adapter.paths, [
        'https://api.trakt.tv/scrobble/stop',
        'https://api.trakt.tv/oauth/token',
        'https://api.trakt.tv/scrobble/stop',
      ]);
      expect(adapter.bearerAt(2), 'Bearer fresh-access');
    });

    test(
      'parallel 401s share one refresh — a second would burn the grant',
      () async {
        final store = _FakeTokenStorage();
        final service = serviceWith(liveSession(), store);

        adapter.reply = (options) {
          if (options.path.endsWith(_tokenUrl)) return _json(refreshedTokens());
          if (options.headers['Authorization'] == 'Bearer live-access') {
            return _json(const {'error': 'unauthorized'}, status: 401);
          }
          return _json(const {}, status: 201);
        };

        await Future.wait([
          service.scrobbleStart(item, episode, 0.1),
          service.scrobblePause(item, episode, 0.2),
          service.scrobbleStop(item, episode, 0.3),
        ]);

        expect(
          adapter.paths
              .where((p) => p == 'https://api.trakt.tv/oauth/token')
              .length,
          1,
        );
      },
    );
  });

  group('a refresh that fails', () {
    test(
      'a rejected grant clears the session, so the tile stops saying Connected',
      () async {
        final store = _FakeTokenStorage();
        final service = serviceWith(expiredSession(), store);

        adapter.reply = (_) =>
            _json(const {'error': 'invalid_grant'}, status: 400);

        final ok = await service.markWatched(item, episode);

        expect(ok, isFalse);
        expect(await service.isLoggedIn, isFalse);
        expect(store.values, isEmpty);
      },
    );

    test(
      'a network failure keeps the session — a tunnel is not a logout',
      () async {
        final store = _FakeTokenStorage();
        final service = serviceWith(expiredSession(), store);

        adapter.reply = (options) => throw DioException.connectionError(
          requestOptions: options,
          reason: 'no route to host',
        );

        final ok = await service.markWatched(item, episode);

        expect(ok, isFalse);
        expect(await service.isLoggedIn, isTrue);
        expect(store.values[refreshKey], 'good-refresh');
      },
    );

    test('a legacy session with no refresh token is cleared on 401', () async {
      final store = _FakeTokenStorage();
      // Installed before refresh tokens were persisted: access token only.
      final service = serviceWith({accessKey: 'legacy-access'}, store);

      adapter.reply = (_) =>
          _json(const {'error': 'unauthorized'}, status: 401);

      final ok = await service.markWatched(item, episode);

      expect(ok, isFalse);
      expect(await service.isLoggedIn, isFalse);
      expect(store.values, isEmpty);
      // No refresh token means no point asking Trakt for one.
      expect(adapter.paths, ['https://api.trakt.tv/scrobble/stop']);
    });
  });

  group('login', () {
    test('stores the refresh token and expiry from the device grant', () async {
      final store = _FakeTokenStorage();
      final service = TraktService(dio, store, clock: clock);

      adapter.reply = (options) {
        if (options.path.endsWith('/oauth/device/code')) {
          return _json({
            'user_code': 'ABCD1234',
            'device_code': 'dev-code',
            'verification_url': 'https://trakt.tv/activate',
            // Keeps the poll loop from sleeping for real seconds.
            'interval': 0,
          });
        }
        return _json({
          'access_token': 'granted-access',
          'refresh_token': 'granted-refresh',
          'expires_in': 7776000,
          'created_at': now.millisecondsSinceEpoch ~/ 1000,
        });
      };

      final ok = await service.login();

      expect(ok, isTrue);
      expect(store.values['trakt_access_token'], 'granted-access');
      expect(store.values['trakt_refresh_token'], 'granted-refresh');
      expect(
        int.parse(store.values['trakt_token_expires_at']!),
        now.add(const Duration(seconds: 7776000)).millisecondsSinceEpoch,
      );
    });
  });
}
