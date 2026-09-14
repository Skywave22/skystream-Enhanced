// Hermetic tests for the local media proxy.
//
// The proxy sits on the playback path for every header-gated stream and every
// ClearKey DASH stream. Everything here runs against a loopback `HttpServer`
// standing in for the CDN, so the assertions are about what the proxy puts on
// the wire: how many connections it opens, and whether it will talk to a
// server whose certificate does not validate.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/services/local_proxy_service.dart';

/// A loopback stand-in for a CDN that records how it was reached.
///
/// [connectionCount] counts handshakes: each TCP connection from the proxy
/// arrives on a distinct ephemeral remote port, so distinct ports across N
/// requests are distinct connections.
class _FakeOrigin {
  _FakeOrigin(this._server, this._handler) {
    _server.listen(
      (request) {
        final remotePort = request.connectionInfo?.remotePort;
        if (remotePort != null) _remotePorts.add(remotePort);
        requestedPaths.add(request.uri.path);
        _handler(request);
      },
      // A rejected TLS handshake surfaces here as a stream error; without this
      // it would escape as an unhandled async error and fail the test for the
      // wrong reason.
      onError: (Object _) {},
    );
  }

  static Future<_FakeOrigin> start(
    void Function(HttpRequest) handler, {
    SecurityContext? security,
  }) async {
    final server = security == null
        ? await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
        : await HttpServer.bindSecure(
            InternetAddress.loopbackIPv4,
            0,
            security,
          );
    return _FakeOrigin(server, handler);
  }

  final HttpServer _server;
  final void Function(HttpRequest) _handler;
  final Set<int> _remotePorts = {};
  final List<String> requestedPaths = [];

  int get port => _server.port;
  int get connectionCount => _remotePorts.length;

  Future<void> close() => _server.close(force: true);
}

/// Reads a URL with a throwaway client, so the test's own connections are
/// never confused with the proxy's.
Future<({int status, String body})> _get(String url) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(Uri.parse(url))).close();
    final body = await response.transform(utf8.decoder).join();
    return (status: response.statusCode, body: body);
  } finally {
    client.close(force: true);
  }
}

void main() {
  late LocalProxyService proxy;
  final origins = <_FakeOrigin>[];

  tearDown(() async {
    await proxy.shutdown();
    for (final origin in origins) {
      await origin.close();
    }
    origins.clear();
  });

  Future<_FakeOrigin> origin(
    void Function(HttpRequest) handler, {
    SecurityContext? security,
  }) async {
    final o = await _FakeOrigin.start(handler, security: security);
    origins.add(o);
    return o;
  }

  group('connection pooling', () {
    // Dart pools keep-alive connections per HttpClient instance, so a client
    // built per request makes every HLS segment pay a fresh TCP - and on
    // https, TLS - handshake.
    test('20 segment fetches reuse a single upstream connection', () async {
      final cdn = await origin((request) {
        final body = utf8.encode('payload-for-${request.uri.path}');
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType('video', 'mp2t')
          ..headers.contentLength = body.length
          ..add(body);
        request.response.close();
      });

      proxy = LocalProxyService();
      await proxy.startServer();

      for (var i = 0; i < 20; i++) {
        final result = await _get(
          proxy.getProxyUrl('http://127.0.0.1:${cdn.port}/seg$i.ts'),
        );
        expect(result.status, 200, reason: 'segment $i');
        expect(result.body, 'payload-for-/seg$i.ts');
      }

      expect(cdn.requestedPaths, hasLength(20));
      expect(
        cdn.connectionCount,
        1,
        reason:
            'the proxy must hold one pooled connection open across segments, '
            'not open ${cdn.connectionCount} of them',
      );
    });

    // One pooled client per autoUncompress mode for the life of the service,
    // never one per request. The factory seam asserts that directly rather
    // than inferring it from socket behaviour.
    test('builds one pooled client per content mode, not one per request',
        () async {
      final cdn = await origin((request) {
        final isPlaylist = request.uri.path.endsWith('.m3u8');
        final body = utf8.encode(
          isPlaylist ? '#EXTM3U\n#EXTINF:6,\nseg0.ts\n' : 'binary',
        );
        request.response
          ..statusCode = 200
          ..headers.contentLength = body.length
          ..add(body);
        request.response.close();
      });

      var clientsBuilt = 0;
      proxy = LocalProxyService(
        httpClientFactory: () {
          clientsBuilt++;
          return HttpClient();
        },
      );
      await proxy.startServer();

      for (var i = 0; i < 20; i++) {
        await _get(proxy.getProxyUrl('http://127.0.0.1:${cdn.port}/seg$i.ts'));
      }
      expect(
        clientsBuilt,
        1,
        reason: '20 binary fetches must share one pooled HttpClient',
      );

      final playlist = await _get(
        proxy.getProxyUrl('http://127.0.0.1:${cdn.port}/playlist.m3u8'),
      );
      expect(playlist.status, 200);
      // A second client, because autoUncompress is a client-level flag that
      // has to be true for playlists and false for binary video.
      expect(clientsBuilt, 2);

      await _get(proxy.getProxyUrl('http://127.0.0.1:${cdn.port}/other.m3u8'));
      expect(clientsBuilt, 2, reason: 'the playlist client is pooled too');
    });

    test('shutdown releases the pooled clients so the next start rebuilds them',
        () async {
      final cdn = await origin((request) {
        request.response
          ..statusCode = 200
          ..headers.contentLength = 2
          ..add(utf8.encode('ok'));
        request.response.close();
      });

      var clientsBuilt = 0;
      proxy = LocalProxyService(
        httpClientFactory: () {
          clientsBuilt++;
          return HttpClient();
        },
      );
      await proxy.startServer();
      await _get(proxy.getProxyUrl('http://127.0.0.1:${cdn.port}/a.ts'));
      expect(clientsBuilt, 1);

      await proxy.shutdown();
      await proxy.startServer();
      await _get(proxy.getProxyUrl('http://127.0.0.1:${cdn.port}/b.ts'));
      expect(
        clientsBuilt,
        2,
        reason: 'shutdown must drop the pooled client, not keep serving a '
            'closed one',
      );
      expect(cdn.connectionCount, 2);
    });
  });

  group('TLS validation', () {
    // This request path replays the plugin's session cookies upstream, so a
    // `badCertificateCallback` that returns true would let an on-path attacker
    // present a self-signed certificate, harvest those cookies and substitute
    // the video.
    test('refuses an upstream whose certificate does not validate', () async {
      final security = SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(utf8.encode(_selfSignedCert))
        ..usePrivateKeyBytes(utf8.encode(_selfSignedKey));

      final cdn = await origin(
        (request) {
          final body = utf8.encode('intercepted-video-bytes');
          request.response
            ..statusCode = 200
            ..headers.contentLength = body.length
            ..add(body);
          request.response.close();
        },
        security: security,
      );

      proxy = LocalProxyService();
      await proxy.startServer();

      final result = await _get(
        proxy.getProxyUrl(
          'https://127.0.0.1:${cdn.port}/movie.mp4',
          headers: {'Cookie': 'session=super-secret'},
        ),
      );

      expect(
        result.status,
        HttpStatus.badGateway,
        reason: 'an untrusted certificate must fail the fetch, not be waved '
            'through',
      );
      expect(result.body, isNot(contains('intercepted-video-bytes')));
      expect(
        cdn.requestedPaths,
        isEmpty,
        reason: 'the handshake must fail before any request (carrying the '
            'session cookie) reaches the impostor',
      );
    });
  });

  group('ClearKey DASH path', () {
    // The CENC handler shares the pooled client. A live manifest refreshes
    // every minimumUpdatePeriod, so the rewrite has to hold across repeated
    // fetches and those refreshes must reuse the connection.
    const manifest = '''
<MPD type="dynamic" minimumUpdatePeriod="PT2S">
  <Period>
    <AdaptationSet mimeType="video/mp4">
      <Representation id="11" bandwidth="1499968">
        <SegmentTemplate timescale="25000"
          media="index_video_11_0_\$Number\$.mp4?m=1732249790"
          initialization="index_video_11_0_init.mp4?m=1732249790"
          startNumber="11329051"/>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>''';

    test('rewrites the manifest and reuses one connection across refreshes',
        () async {
      final cdn = await origin((request) {
        final body = utf8.encode(manifest);
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType('application', 'dash+xml')
          ..headers.contentLength = body.length
          ..add(body);
        request.response.close();
      });

      proxy = LocalProxyService();
      await proxy.startServer();

      final url = proxy.getDecryptingDashUrl(
        'http://127.0.0.1:${cdn.port}/stream.mpd',
        key: Uint8List.fromList(List.filled(16, 0xAB)),
        keyId: Uint8List.fromList(List.filled(16, 0xCD)),
      );

      late String body;
      for (var i = 0; i < 4; i++) {
        final result = await _get(url);
        expect(result.status, 200, reason: 'manifest refresh $i');
        body = result.body;
      }

      expect(body, contains('/cenc?url='));
      // VLC substitutes the token textually before requesting a segment, so a
      // percent-encoded dollar means it silently never asks for anything.
      expect(body, contains(r'$Number$'));
      expect(body, isNot(contains('%24')));
      expect(
        cdn.connectionCount,
        1,
        reason: 'manifest refreshes must not each cost a handshake',
      );
    });
  });
}

// A throwaway self-signed certificate for 127.0.0.1, valid until 2126. It is
// in no trust store, so a correct client must refuse it.
const String _selfSignedCert = '''
-----BEGIN CERTIFICATE-----
MIIDHDCCAgSgAwIBAgIUZwxDUHTdlfONWD3vF1XEbMJcghkwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJMTI3LjAuMC4xMCAXDTI2MDkxMzAxMDQzMloYDzIxMjYw
ODIwMDEwNDMyWjAUMRIwEAYDVQQDDAkxMjcuMC4wLjEwggEiMA0GCSqGSIb3DQEB
AQUAA4IBDwAwggEKAoIBAQCgRvjl1BzFC9hK7hd34+/E2mApz58hYCSxhF2zUrde
wvOjacj9Fy/+ObWXliVGRS4nJrryiLu7iPsSs6Tcft9M5OI6J1akTl3uOLnhsV6c
uXsoyRht9sXk7r1whzePLt6HPTbXXk3ImteXWz/kvoP9ltYCpX1ohlx8VZn/izlw
tEkNcOhogOE9mXxmE7HFhajxCtj0pmbLwknQyf3MQB/fS9WY6BQNs85cINYawAlq
9NneQBDRFVOQ/Rk4ILwFdGbMn1ODjT2dA/tNWZoSTrIXfvM8yb596palcgOCFk+9
jKcK9jhfHOIuwUcQQw+RHqsY7JLXtjKOmAs019LBqIIvAgMBAAGjZDBiMB0GA1Ud
DgQWBBR0BIOzOVioE/ut8yOi79dzay/cSzAfBgNVHSMEGDAWgBR0BIOzOVioE/ut
8yOi79dzay/cSzAPBgNVHRMBAf8EBTADAQH/MA8GA1UdEQQIMAaHBH8AAAEwDQYJ
KoZIhvcNAQELBQADggEBADASqexZmix/IbxTdaEDGnTu0Kezzh2nUQ/SyJA+XM1V
WwkINN1Yo9V4acKPLJOMeQZ+AkhCUN8whC4KZdSL0FpgElHOvkDZneGLrVsfJw09
RR8SxAi9ia8UOxZ5NE0ZMM/btfDrQN1XryEY8NtbAKuTQJGWqgKzzcBxwwHHXnaq
dHzDfid0g3jCxCF7AHeViA1SabTgqlaDXV7l5Rxkn2V42gs9rapO2Tv1kZiXh9eq
MxDj0RX8Qi6cTxvSEGkz4Iaimj4OX+C0+rjsnTJ2PoXS0eV4TR1EwF3T0/zWY2xz
ZHtRVP1CXusbr7tSj+A5YZrRf/uAwaunBVmHGZTqm2E=
-----END CERTIFICATE-----
''';

const String _selfSignedKey = '''
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCgRvjl1BzFC9hK
7hd34+/E2mApz58hYCSxhF2zUrdewvOjacj9Fy/+ObWXliVGRS4nJrryiLu7iPsS
s6Tcft9M5OI6J1akTl3uOLnhsV6cuXsoyRht9sXk7r1whzePLt6HPTbXXk3ImteX
Wz/kvoP9ltYCpX1ohlx8VZn/izlwtEkNcOhogOE9mXxmE7HFhajxCtj0pmbLwknQ
yf3MQB/fS9WY6BQNs85cINYawAlq9NneQBDRFVOQ/Rk4ILwFdGbMn1ODjT2dA/tN
WZoSTrIXfvM8yb596palcgOCFk+9jKcK9jhfHOIuwUcQQw+RHqsY7JLXtjKOmAs0
19LBqIIvAgMBAAECggEAFXa7sUeRHMBD1HEDGo6fVuzpsN+5j0YpU86Gn9Olc97G
su0hOeeHiVOgIm88iacNEbgpk/5Eqc4j1XLSUqb473q9Yw1OmI1YHeVh2zweD/30
5NbdWyiPguOH4hBxm86qhVDozbm2z/UQhxf0vATZdzXibhNMcpl/vDTYfTTfWdzM
pBMvgJANM8sCAbwgNL55GbXrz88mlqnMIphETdfI9RVhCbjZKCZ+Snf3wUzcFDXO
WeOLaynqjkAQH5MEnQOHRFMeGQYW1pSNK486WbBiqO0ElSBvrCzVTHrpHyEMG2eV
JSBPr5p4IS79pjTMjaHMFHcI6fxj+sAYH0FAY32kQQKBgQDMoV6rPyC9ifd0aN2f
rZNfIektM6whmCW8oK1s92E8ufJeguRt+WYuYsYN0Pu0upMfI29447FyxUUym6yP
6PzGcg8QYa1itobw80X5ApB8tx455DgWBWElKOQouEbEwZbBwfReZOwu7gFIIOzG
0LeUE7zxDOFJ/W1WqocNf+DxwQKBgQDIgzyAk/xnUcttddW+D+BEO4Ws7a4OIuaw
ndj0lev5rsD/DazgBe7movaym6A1cnltYgroUzVrnq2jGJAcTQAC8te2prfiHVux
dOo6Bm5oNWgw490yUcG9Z18YFd0KinHRXxMf+GgKjPqov/umLmcRtDIOeYPGxVj/
9exD5pyP7wKBgQCKQ7btyrfamfBj7b9h9yyOqSEe870o7d8Btye3aud+2r2Tcqna
TRvn18Gu8DhDA5YJAi595out2vFIortUeb7ib4sSLI21F1PSVu4+tKbgPfLkdvoW
lwfuzdRsVycqJwwwW1c8uMCFbTfcfrK+G6UPHs8ZqPRIxD4uwwaB7pgVgQKBgDiz
zBc8QiNhoRpqOTCPQsdo4at+Zzs+KWiGqsS35Mxt28wErP+JDf8Q1Jy7n7mdjrMd
B6KdbTzq2YWGu7IVIEy1KcVQLi32SWjMfDQ+f1heygERXwsMzbHnGqAwBpslfXxM
25at45YgOf4glGRxONprz8ACIv7B7iIsBE1LWLjnAoGASA1FfeijhzhFu+2bqZOz
KA8BKyN6WDb3MlnuyAwLSksELvtonFz0YUE8oEO622kOylfrJJ0JPU2a8TOu22+N
k513+xm/TgBonbpOV0Zc6P9ezZtGSDRXMx8qv6SixPByvcugN7VHjF+KkRvUeT/A
ebCRe6aAS1PlHhTFzCTC5RA=
-----END PRIVATE KEY-----
''';
