import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/network/dio_client_provider.dart';
import 'package:skystream/core/network/doh_service.dart';

/// Stands in for the DoH endpoint. [blocked] models the case the audit found:
/// a captive portal or an ISP that black-holes the resolver, so the request
/// neither connects nor fails fast.
class _FakeDohEndpoint implements HttpClientAdapter {
  _FakeDohEndpoint();

  int calls = 0;
  bool blocked = true;

  /// When set, the "connection" hangs for this long before failing — the
  /// behaviour that makes an unreachable endpoint expensive rather than cheap.
  Duration stall = Duration.zero;

  /// Names the endpoint knows about when it is reachable.
  final Map<String, String> zone = <String, String>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    if (stall > Duration.zero) await Future<void>.delayed(stall);
    if (blocked) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'network is unreachable',
      );
    }
    final String name = options.queryParameters['name'] as String;
    final String? ip = zone[name];
    return ResponseBody.fromString(
      jsonEncode(
        ip == null
            ? <String, Object?>{'Status': 3}
            : <String, Object?>{
                'Status': 0,
                'Answer': <Object?>[
                  <String, Object?>{'type': 1, 'data': ip, 'TTL': 300},
                ],
              },
      ),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/dns-json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A clock the test drives by hand, so cooldowns can lapse without waiting.
class _FakeClock {
  DateTime now = DateTime.utc(2026, 1, 1, 12);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

void main() {
  late _FakeDohEndpoint endpoint;
  late _FakeClock clock;
  late DohService doh;

  DohService build({Duration resolveTimeout = DohService.kResolveTimeout}) {
    final Dio dio = Dio()..httpClientAdapter = endpoint;
    return DohService.forTesting(
      dio: dio,
      clock: clock.call,
      resolveTimeout: resolveTimeout,
    )..applySettings(
      const DohSettings(
        enabled: true,
        provider: DohProvider.custom,
        customUrl: 'https://doh.test/dns-query',
      ),
    );
  }

  setUp(() {
    endpoint = _FakeDohEndpoint();
    clock = _FakeClock();
    doh = build();
  });

  group('negative cache', () {
    test(
      'a failed lookup is not retried on the very next request for that host',
      () async {
        expect(await doh.resolve('api.example.test'), isNull);
        expect(endpoint.calls, 1);

        expect(await doh.resolve('api.example.test'), isNull);
        expect(
          endpoint.calls,
          1,
          reason:
              'the second request must be served from the negative cache, '
              'not re-pay the full DoH timeout',
        );
      },
    );

    test('the negative entry expires so a recovered host resolves again', () async {
      expect(await doh.resolve('api.example.test'), isNull);
      expect(endpoint.calls, 1);

      endpoint.blocked = false;
      endpoint.zone['api.example.test'] = '203.0.113.7';

      // Still inside the negative TTL: no network, still null.
      clock.advance(DohService.kNegativeCacheTtl - const Duration(seconds: 1));
      expect(await doh.resolve('api.example.test'), isNull);
      expect(endpoint.calls, 1);

      clock.advance(const Duration(seconds: 2));
      expect(await doh.resolve('api.example.test'), '203.0.113.7');
      expect(endpoint.calls, 2);
    });

    test('a successful lookup is still cached for its TTL', () async {
      endpoint.blocked = false;
      endpoint.zone['cdn.example.test'] = '198.51.100.9';

      expect(await doh.resolve('cdn.example.test'), '198.51.100.9');
      expect(await doh.resolve('cdn.example.test'), '198.51.100.9');
      expect(endpoint.calls, 1);
    });
  });

  test('concurrent lookups for one host share a single query', () async {
    endpoint.blocked = false;
    endpoint.zone['many.example.test'] = '192.0.2.5';

    final List<String?> results = await Future.wait(<Future<String?>>[
      doh.resolve('many.example.test'),
      doh.resolve('many.example.test'),
      doh.resolve('many.example.test'),
    ]);

    expect(results, <String?>['192.0.2.5', '192.0.2.5', '192.0.2.5']);
    expect(endpoint.calls, 1);
  });

  group('circuit breaker', () {
    test('stops touching a blocked endpoint after the failure threshold, '
        'and closes again once it recovers', () async {
      // Distinct hosts, so the negative cache cannot be what suppresses these.
      for (int i = 0; i < DohService.kFailureThreshold; i++) {
        expect(await doh.resolve('host$i.example.test'), isNull);
      }
      expect(endpoint.calls, DohService.kFailureThreshold);
      expect(doh.isDegraded, isTrue);
      expect(doh.status.value, DohStatus.degraded);

      // Every further host now falls straight through to the system resolver.
      for (int i = 0; i < 20; i++) {
        expect(await doh.resolve('later$i.example.test'), isNull);
      }
      expect(
        endpoint.calls,
        DohService.kFailureThreshold,
        reason: 'the breaker must keep the blocked endpoint off the hot path',
      );

      // The portal gets signed into. The breaker must let a probe through
      // on its own — no restart, no setting change.
      endpoint.blocked = false;
      endpoint.zone['after.example.test'] = '203.0.113.42';
      clock.advance(DohService.kBreakerCooldown + const Duration(seconds: 1));

      expect(await doh.resolve('after.example.test'), '203.0.113.42');
      expect(doh.isDegraded, isFalse);
      expect(doh.status.value, DohStatus.active);
    });

    test('a still-blocked endpoint costs one probe per cooldown, not one per '
        'request', () async {
      for (int i = 0; i < DohService.kFailureThreshold; i++) {
        await doh.resolve('host$i.example.test');
      }
      expect(endpoint.calls, DohService.kFailureThreshold);

      clock.advance(DohService.kBreakerCooldown + const Duration(seconds: 1));

      // Half-open: exactly one of these ten reaches the wire.
      for (int i = 0; i < 10; i++) {
        expect(await doh.resolve('probe$i.example.test'), isNull);
      }
      expect(endpoint.calls, DohService.kFailureThreshold + 1);
      expect(doh.isDegraded, isTrue);
    });

    test('the cooldown backs off, but never past the ceiling', () async {
      for (int i = 0; i < DohService.kFailureThreshold; i++) {
        await doh.resolve('h$i.example.test');
      }

      Duration probe(Duration afterFirstTrip) => afterFirstTrip;

      // First cooldown: 30 s. Not yet lapsed at 29 s.
      clock.advance(DohService.kBreakerCooldown - const Duration(seconds: 1));
      await doh.resolve('a.example.test');
      expect(endpoint.calls, DohService.kFailureThreshold);

      // Lapsed: one probe, which fails, so the breaker re-opens for longer.
      clock.advance(probe(const Duration(seconds: 2)));
      await doh.resolve('b.example.test');
      expect(endpoint.calls, DohService.kFailureThreshold + 1);

      // Second cooldown must exceed the first.
      clock.advance(DohService.kBreakerCooldown + const Duration(seconds: 1));
      await doh.resolve('c.example.test');
      expect(
        endpoint.calls,
        DohService.kFailureThreshold + 1,
        reason: 'the second cooldown should be longer than the first',
      );

      clock.advance(DohService.kBreakerMaxCooldown);
      await doh.resolve('d.example.test');
      expect(endpoint.calls, DohService.kFailureThreshold + 2);
    });

    test('changing the DoH provider gives the new endpoint a clean slate', () async {
      for (int i = 0; i < DohService.kFailureThreshold; i++) {
        await doh.resolve('h$i.example.test');
      }
      expect(doh.isDegraded, isTrue);

      doh.applySettings(
        const DohSettings(enabled: true, provider: DohProvider.quad9),
      );

      expect(doh.isDegraded, isFalse);
      expect(doh.status.value, DohStatus.active);
    });

    test('clearCache is an explicit retry: it closes the breaker', () async {
      for (int i = 0; i < DohService.kFailureThreshold; i++) {
        await doh.resolve('h$i.example.test');
      }
      expect(doh.isDegraded, isTrue);

      doh.clearCache();

      expect(doh.isDegraded, isFalse);
      endpoint.blocked = false;
      endpoint.zone['fresh.example.test'] = '192.0.2.77';
      expect(await doh.resolve('fresh.example.test'), '192.0.2.77');
    });

    test('turning DoH off reports off, not degraded', () async {
      for (int i = 0; i < DohService.kFailureThreshold; i++) {
        await doh.resolve('h$i.example.test');
      }
      expect(doh.status.value, DohStatus.degraded);

      doh.applySettings(const DohSettings(enabled: false));
      expect(doh.status.value, DohStatus.off);
      expect(await doh.resolve('anything.example.test'), isNull);
    });
  });

  test('a stalled endpoint is abandoned at the resolve budget', () async {
    doh = build(resolveTimeout: const Duration(milliseconds: 40));
    endpoint.stall = const Duration(seconds: 30);

    final Stopwatch sw = Stopwatch()..start();
    expect(await doh.resolve('slow.example.test'), isNull);
    sw.stop();

    expect(
      sw.elapsed,
      lessThan(const Duration(seconds: 5)),
      reason: 'resolve() must not outlive its own budget',
    );
    // And the timeout counts against the endpoint, not the name.
    expect(await doh.resolve('slow2.example.test'), isNull);
    expect(await doh.resolve('slow3.example.test'), isNull);
    expect(doh.isDegraded, isTrue);
  });

  test('the DoH wait stays inside the connect budget the app advertises', () {
    // dart:io applies HttpClient.connectionTimeout to the socket only after the
    // connectionFactory future resolves, so this wait is ADDED to the
    // advertised budget. It must therefore be strictly smaller than it —
    // at 15 s it doubled the worst case per request to 30 s.
    expect(kDohResolveGuard, lessThan(kDioConnectTimeout));
    expect(
      kDohResolveGuard,
      greaterThanOrEqualTo(DohService.kResolveTimeout),
      reason: 'the guard is a backstop; the service must time out first',
    );
  });
}
