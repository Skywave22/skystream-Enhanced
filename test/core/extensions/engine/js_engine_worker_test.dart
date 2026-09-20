@Timeout(Duration(seconds: 60))
library;

import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/extensions/engine/js_engine.dart'
    show buildBridgeResponse;
import 'package:skystream/core/extensions/engine/js_engine_worker.dart';

/// Drives the real [JsWorkerRunner] — real QuickJS, real eval queue, real
/// pump timers — on the test isolate, with a [ReceivePort] standing in for
/// the main isolate.
///
/// Covers the two job-pump accounting leaks (audit W11) and the bridge
/// payload hand-off (audit W24). The message keys are the wire protocol
/// declared at the top of js_engine_worker.dart; they are private there, so
/// they are spelled out here on purpose — a rename that breaks the protocol
/// should break this test.
void main() {
  group('JsWorkerRunner job pump', () {
    late _Harness h;

    setUp(() => h = _Harness());
    tearDown(() => h.dispose());

    test(
      'a cancelled invoke releases the 16 ms pump — audit W11, stuck high',
      () async {
        await h.load('''
          globalThis.p = {
            hang: function(cb) { return new Promise(function() {}); }
          };
        ''');

        h.invoke(7, 'p.hang');
        await h.settle();
        expect(
          h.runner.inFlightInvokes,
          1,
          reason: 'the invoke is waiting on a callback that will never fire',
        );
        expect(h.runner.isPumpFast, isTrue);
        final int ticksWhileBusy = h.runner.pumpTicks;
        await h.settle(const Duration(milliseconds: 250));
        expect(
          h.runner.pumpTicks - ticksWhileBusy,
          greaterThan(6),
          reason: 'sanity: the fast pump really is ticking while busy',
        );

        // What the main isolate's 90 s invokeAsync timeout sends. The plugin
        // never called back — nothing else will ever decrement for it.
        h.runner.handle(<String, Object?>{'ci': 1, 'id': 7});

        expect(h.runner.inFlightInvokes, 0);

        // The measurement that matters: no work at all on an idle engine. A
        // stuck-high pump ticks ~15 times in this window, each tick eight
        // executePendingJob FFI calls, for the life of the process.
        final int ticksAtCancel = h.runner.pumpTicks;
        await h.settle(const Duration(milliseconds: 250));
        expect(
          h.runner.pumpTicks - ticksAtCancel,
          0,
          reason: 'the engine is idle; every tick here is battery burnt',
        );
        expect(h.runner.isPumpFast, isFalse);
      },
    );

    test(
      'a double-dispatched callback cannot wedge the pump — audit W11, stuck low',
      () async {
        // The invoke wrapper both passes dart_cb as the last argument and
        // chains it onto a returned promise, so a plugin that uses both
        // calling conventions dispatches the same callback id twice. The
        // second dispatch used to decrement a second time, leaving the
        // counter negative and the fast pump permanently unreachable.
        await h.load('''
          globalThis.p = {
            both: function(cb) { cb('sync'); return Promise.resolve('async'); },
            hang: function(cb) { return new Promise(function() {}); }
          };
        ''');

        h.invoke(1, 'p.both');
        await h.awaitInvokeResult(1);
        await h.settle();
        expect(h.runner.inFlightInvokes, 0);
        expect(h.runner.isPumpFast, isFalse);

        // A perfectly ordinary plugin call after the double dispatch.
        final int ticksBefore = h.runner.pumpTicks;
        h.invoke(2, 'p.hang');
        await h.settle(const Duration(milliseconds: 250));
        expect(
          h.runner.pumpTicks - ticksBefore,
          greaterThan(6),
          reason:
              'the fast pump must engage for this call; a wedged counter '
              'leaves every later invoke on the 1 Hz idle pump',
        );
        expect(
          h.runner.isPumpFast,
          isTrue,
          reason: 'an invoke is in flight, so the pump must be fast',
        );
      },
    );

    test(
      'a disposed worker does not restart its pump for a late message',
      () async {
        h.runner.handle(<String, Object?>{'dp': 1});
        final int ticksAtDispose = h.runner.pumpTicks;

        // The main isolate kills this isolate right after _mDispose, but an
        // already-queued message can still land first.
        h.invoke(5, 'p.hang');
        await h.settle(const Duration(milliseconds: 250));

        expect(
          h.runner.pumpTicks - ticksAtDispose,
          0,
          reason: 'a torn-down worker must not pump a freed runtime',
        );
        expect(h.runner.isPumpFast, isFalse);
      },
    );

    test('a plain invoke returns the pump to idle when it resolves', () async {
      await h.load("globalThis.p = { echo: function(v, cb) { cb(v); } };");

      h.invoke(3, 'p.echo', args: <Object?>['hi']);
      final result = await h.awaitInvokeResult(3);

      expect(result['result'], 'hi');
      expect(h.runner.inFlightInvokes, 0);
      expect(h.runner.isPumpFast, isFalse);
    });
  });

  group('JsWorkerRunner bridge payload', () {
    late _Harness h;

    setUp(() => h = _Harness());
    tearDown(() => h.dispose());

    test('the main isolate hands over an unencoded result and the worker '
        'serialises it — audit W24', () async {
      await h.load('''
          globalThis.p = {
            fetch: function(cb) {
              return http_get('https://example.test/page', {}).then(
                function(res) { return res.body; }
              );
            }
          };
        ''');

      h.invoke(11, 'p.fetch');
      final bridge = await h.awaitMessage(
        (Map<Object?, Object?> m) => m['ch'] == 'http_request',
      );
      final args = jsonDecode(bridge['aj'] as String) as Map<String, dynamic>;

      // Exactly what JsEngineService._reply puts on the port.
      final reply = buildBridgeResponse(
        bid: bridge['bid'] as int,
        jsId: args['id'] as String,
        result: <String, Object?>{
          'code': 200,
          'status': 200,
          'body': '<html>scraped</html>',
          'headers': <String, String>{'content-type': 'text/html'},
        },
      );

      expect(
        reply['rv'],
        isA<Map<Object?, Object?>>(),
        reason:
            'the payload must cross the port as a live object: encoding a '
            'multi-MB page here would block the isolate that draws the UI',
      );
      expect(
        reply.values.whereType<String>().any((String v) => v.contains('{')),
        isFalse,
        reason: 'no field may carry JSON encoded on the main isolate',
      );

      h.runner.handle(reply);
      final result = await h.awaitInvokeResult(11);
      expect(result['result'], '<html>scraped</html>');
    });
  });

  // ── Crypto polyfills (bridge payload encoding) ────────────────────────────
  //
  // nativeMd5 and nativeSha256 used to hand `sendMessage` a RAW string while
  // both engine bindings jsonDecode the payload unconditionally. Two failure
  // modes, neither visible to a compiler: ordinary text threw FormatException
  // into the plugin on QuickJS and returned undefined on JavaScriptCore, and
  // input that happened to parse as JSON was worse still — the handler hashed
  // Dart's Map.toString(), so nativeMd5('{"a":1}') returned md5('{a: 1}').
  //
  // This file runs against QuickJS on CI's ubuntu leg and against
  // JavaScriptCore on a developer Mac, so these cover both engines.
  group('JsWorkerRunner crypto polyfills', () {
    late _Harness h;

    setUp(() => h = _Harness());
    tearDown(() => h.dispose());

    test('nativeMd5 hashes the string the plugin passed', () async {
      await h.load(r"globalThis.p = { hash: function(s) { return nativeMd5(s); } };");
      h.invoke(21, 'p.hash', args: <Object?>['hello']);
      final Map<Object?, Object?> result = await h.awaitInvokeResult(21);
      expect(result['result'], '5d41402abc4b2a76b9719d911017c592');
    });

    test('a JSON-shaped string hashes as itself, not as a parsed Map', () async {
      // The regression case: this input parses as JSON, so the old code did
      // reach the handler — and confidently hashed `{a: 1}` instead.
      await h.load(r"globalThis.p = { hash: function(s) { return nativeMd5(s); } };");
      h.invoke(22, 'p.hash', args: <Object?>[r'{"a":1}']);
      final Map<Object?, Object?> result = await h.awaitInvokeResult(22);
      expect(
        result['result'],
        'bb6cb5c68df4652941caf652a366f2d8',
        reason: "md5 of the literal string; md5 of Dart's Map.toString() is a "
            'different digest the plugin never asked for',
      );
    });

    test('nativeSha256 hashes the string the plugin passed', () async {
      await h.load(r"globalThis.p = { hash: function(s) { return nativeSha256(s); } };");
      h.invoke(23, 'p.hash', args: <Object?>['hello']);
      final Map<Object?, Object?> result = await h.awaitInvokeResult(23);
      expect(
        result['result'],
        '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
      );
    });
  });

  // ── Shared-realm lockdown (audit W12) ─────────────────────────────────────
  //
  // Every plugin evals into this one runtime, and a plugin's bridge calls hand
  // its capability token to `sendMessage`, `_dartAsyncCall` and
  // `JSON.stringify` on the way out. If a plugin loaded earlier can replace
  // any of them — or hook `Object.prototype` for the token field — it reads
  // every later plugin's token and, holding it, is that plugin at the bridge.
  // The end-to-end theft is pinned in js_engine_bridge_attribution_test.dart;
  // this pins the seals themselves, including the ones no plugin-level test
  // reaches (`_resolveDartAsync` and `executeCallback` carry bridge *results*
  // back into a plugin, so hijacking them reads another plugin's stored data
  // straight off the wire).
  group('JsWorkerRunner shared-realm lockdown', () {
    late _Harness h;

    setUp(() => h = _Harness());
    tearDown(() => h.dispose());

    test('a plugin cannot replace the bridge primitives', () async {
      await h.load(r'''
        (function () {
          var names = ['sendMessage', '_dartAsyncCall', '_resolveDartAsync',
                       'executeCallback', 'JSON'];
          var orig = {};
          for (var i = 0; i < names.length; i++) {
            orig[names[i]] = globalThis[names[i]];
          }
          var origStringify = JSON.stringify;
          var evil = function () { return 'pwned'; };

          for (var i = 0; i < names.length; i++) {
            try { globalThis[names[i]] = evil; } catch (e) {}
            try {
              Object.defineProperty(globalThis, names[i], { value: evil });
            } catch (e) {}
          }
          try { JSON.stringify = evil; } catch (e) {}
          try {
            Object.defineProperty(JSON, 'stringify', { value: evil });
          } catch (e) {}

          var breached = [];
          for (var i = 0; i < names.length; i++) {
            if (globalThis[names[i]] !== orig[names[i]]) breached.push(names[i]);
          }
          if (JSON.stringify !== origStringify) breached.push('JSON.stringify');

          // The token field must not be turnable into an accessor...
          try {
            Object.defineProperty(Object.prototype, '__ssTok', {
              configurable: true,
              get: function () { return undefined; },
              set: function (v) {}
            });
            breached.push('Object.prototype.__ssTok');
          } catch (e) {}
          // ...and neither must the serialiser's toJSON hook.
          try {
            Object.prototype.toJSON = evil;
            if (({}).toJSON === evil) breached.push('Object.prototype.toJSON');
          } catch (e) {}

          // ...while an object's OWN toJSON keeps working, because plugins use
          // it and this lockdown has to be invisible to them.
          var own = { a: 1 };
          own.toJSON = function () { return { a: 2 }; };
          if (origStringify(own) !== '{"a":2}') breached.push('own-toJSON-broken');

          // Reported through the references captured BEFORE the attack, so
          // the report still arrives when the seals are gone and `console`
          // itself is going through the attacker's sendMessage.
          orig['sendMessage'](
            'console_log',
            origStringify('BREACHED[' + breached.join(',') + ']')
          );
        })();
      ''');

      final String report = h.logs.firstWhere(
        (String l) => l.contains('BREACHED'),
        orElse: () => 'the probe never logged',
      );
      expect(
        report,
        contains('BREACHED[]'),
        reason:
            'each name listed is a shared primitive a plugin can swap out, '
            'and every one of them carries another plugin\'s capability token '
            'or its bridge results',
      );
    });
  });
}

class _Harness {
  _Harness() {
    _rx.listen((Object? m) {
      if (m is! Map) return;
      final Map<Object?, Object?> msg = m.cast<Object?, Object?>();
      messages.add(msg);
      if (msg.containsKey('ll')) logs.add(msg['ll'] as String);
    });
    runner = JsWorkerRunner(_rx.sendPort);
  }

  final ReceivePort _rx = ReceivePort();
  final List<Map<Object?, Object?>> messages = <Map<Object?, Object?>>[];
  final List<String> logs = <String>[];
  late final JsWorkerRunner runner;
  int _loadId = 1000;

  Future<void> load(String script) async {
    final int id = _loadId++;
    runner.handle(<String, Object?>{
      'ls': 1,
      'id': id,
      'payload': script,
      'tag': null,
    });
    await awaitMessage((Map<Object?, Object?> m) {
      if (m.containsKey('le') && m['le'] == id) {
        fail('script failed to load: ${m['msg']}');
      }
      return m['ld'] == id;
    });
  }

  void invoke(int id, String fn, {List<Object?> args = const <Object?>[]}) {
    runner.handle(<String, Object?>{
      'iv': 1,
      'id': id,
      'fn': fn,
      'aj': jsonEncode(args),
    });
  }

  Future<Map<Object?, Object?>> awaitInvokeResult(
    int id, {
    Duration timeout = const Duration(seconds: 10),
  }) => awaitMessage(
    (Map<Object?, Object?> m) => m['ir'] == id,
    timeout: timeout,
  );

  Future<Map<Object?, Object?>> awaitMessage(
    bool Function(Map<Object?, Object?>) matches, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      for (final Map<Object?, Object?> m in messages) {
        if (matches(m)) return m;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw StateError('no matching worker message within $timeout: $messages');
  }

  Future<void> settle([Duration d = const Duration(milliseconds: 120)]) =>
      Future<void>.delayed(d);

  void dispose() {
    runner.handle(<String, Object?>{'dp': 1});
    _rx.close();
  }
}
