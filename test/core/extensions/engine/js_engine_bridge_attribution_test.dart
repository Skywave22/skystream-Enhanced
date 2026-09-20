// Plugin bridge calls are attributed by a token Dart minted, not by anything
// the plugin sends and not by the worker's most-recently-started callback.
//
// These drive JsEngineService's bridge dispatch directly: the worker forwards
// `{bg:1, bid, ch, aj, iid}` and the main isolate decides whose data the call
// may touch.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/extensions/engine/js_engine.dart';
import 'package:skystream/core/extensions/engine/js_engine_worker.dart';
import 'package:skystream/core/extensions/providers/js_based_provider.dart';
import 'package:skystream/core/storage/extension_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';

class _FakeExtensionRepository extends ExtensionRepository {
  _FakeExtensionRepository() : super(StorageService());

  final Map<String, String?> data = <String, String?>{};

  @override
  String? getExtensionData(String key) => data[key];

  @override
  Future<void> setExtensionData(String key, String? value) async {
    data[key] = value;
  }
}

/// Stands in for the QuickJS worker isolate: collects everything the engine
/// sends back so a test can read the value a bridge call answered with.
class _WorkerStub {
  _WorkerStub() {
    _port.listen((dynamic m) => sent.add(m as Map<dynamic, dynamic>));
  }

  final ReceivePort _port = ReceivePort();
  final List<Map<dynamic, dynamic>> sent = <Map<dynamic, dynamic>>[];

  SendPort get sendPort => _port.sendPort;
  void close() => _port.close();

  /// The value the engine replied with for the JS-side async call [jsId].
  Object? replyFor(String jsId) => sent.firstWhere(
    (m) => m['jsId'] == jsId,
    orElse: () => throw StateError('no bridge reply for $jsId in $sent'),
  )['rv'];

  bool hasReplyFor(String jsId) => sent.any((m) => m['jsId'] == jsId);
}

/// Never answers. Records whether Dio handed it a live cancellation future.
class _BlockingAdapter implements HttpClientAdapter {
  int started = 0;
  int cancelled = 0;
  final List<String> urls = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    started++;
    urls.add(options.uri.toString());
    final completer = Completer<ResponseBody>();
    cancelFuture?.then((_) {
      cancelled++;
      if (!completer.isCompleted) {
        completer.completeError(
          DioException.requestCancelled(
            requestOptions: options,
            reason: 'cancelled',
          ),
        );
      }
    });
    return completer.future;
  }

  @override
  void close({bool force = false}) {}
}

/// The message the worker forwards for one `sendMessage(channel, ...)`.
Map<String, dynamic> _bridgeMsg({
  required int bid,
  required String channel,
  required Map<String, dynamic> args,
  String? iid,
}) => <String, dynamic>{
  'bg': 1,
  'bid': bid,
  'ch': channel,
  'aj': jsonEncode(args),
  'iid': iid,
};

void main() {
  late _FakeExtensionRepository repo;
  late _WorkerStub worker;
  late JsEngineService engine;
  late _BlockingAdapter adapter;

  setUp(() {
    repo = _FakeExtensionRepository();
    worker = _WorkerStub();
    adapter = _BlockingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    engine = JsEngineService.withWorkerPort(repo, dio, worker.sendPort);
  });

  tearDown(() {
    engine.dispose();
    worker.close();
  });

  group('storage namespace is a boundary', () {
    test('plugin B cannot read a key plugin A wrote', () async {
      final tokenA = engine.mintBridgeToken(
        namespace: 'com_a__sub1',
        packageName: 'com.a',
      );
      final tokenB = engine.mintBridgeToken(
        namespace: 'com_b__sub1',
        packageName: 'com.b',
      );

      // A stores its debrid session.
      engine.handleWorkerMessage(
        _bridgeMsg(
          bid: 1,
          channel: 'set_storage',
          args: {'__ssTok': tokenA, 'key': 'session', 'value': 'A-SECRET'},
        ),
      );
      await pumpEventQueue();

      // B asks for the same key under its own, entirely valid, identity.
      engine.handleWorkerMessage(
        _bridgeMsg(
          bid: 2,
          channel: 'get_storage',
          args: {'id': 'b_read', '__ssTok': tokenB, 'key': 'session'},
        ),
      );
      await pumpEventQueue();
      expect(
        worker.replyFor('b_read'),
        isNull,
        reason: "plugin B read plugin A's storage key",
      );

      // B naming A the only ways JS can — a packageName field, A's namespace,
      // A's raw namespace as a token.
      engine.handleWorkerMessage(
        _bridgeMsg(
          bid: 3,
          channel: 'get_storage',
          args: {
            'id': 'b_forge',
            '__ssTok': 'com_a__sub1',
            'packageName': 'com.a',
            'namespace': 'com_a__sub1',
            'key': 'session',
          },
        ),
      );
      await pumpEventQueue();
      expect(
        worker.replyFor('b_forge'),
        isNull,
        reason: "a forged identity reached plugin A's storage",
      );

      // A still reads its own.
      engine.handleWorkerMessage(
        _bridgeMsg(
          bid: 4,
          channel: 'get_storage',
          args: {'id': 'a_read', '__ssTok': tokenA, 'key': 'session'},
        ),
      );
      await pumpEventQueue();
      expect(worker.replyFor('a_read'), 'A-SECRET');

      // And the write is namespaced on disk rather than sharing one key space.
      expect(repo.data.containsKey('com_a::session'), isTrue);
      expect(repo.data.containsKey('session'), isFalse);
    });

    test('sub-providers of one plugin share that plugin\'s key space', () async {
      final sub1 = engine.mintBridgeToken(
        namespace: 'com_a__sub1',
        packageName: 'com.a',
      );
      final sub2 = engine.mintBridgeToken(
        namespace: 'com_a__sub2',
        packageName: 'com.a',
      );

      engine.handleWorkerMessage(
        _bridgeMsg(
          bid: 1,
          channel: 'set_storage',
          args: {'__ssTok': sub1, 'key': 'session', 'value': 'shared'},
        ),
      );
      await pumpEventQueue();
      engine.handleWorkerMessage(
        _bridgeMsg(
          bid: 2,
          channel: 'get_storage',
          args: {'id': 'sub2_read', '__ssTok': sub2, 'key': 'session'},
        ),
      );
      await pumpEventQueue();

      expect(worker.replyFor('sub2_read'), 'shared');
    });

    test('an untokened bridge call is refused, not served the flat key '
        'space', () async {
      repo.data['session'] = 'LEGACY-FLAT-VALUE';

      engine.handleWorkerMessage(
        _bridgeMsg(
          bid: 1,
          channel: 'get_storage',
          args: {'id': 'anon_read', 'key': 'session'},
        ),
      );
      await pumpEventQueue();
      expect(worker.replyFor('anon_read'), isNull);

      engine.handleWorkerMessage(
        _bridgeMsg(
          bid: 2,
          channel: 'set_storage',
          args: {'key': 'session', 'value': 'HIJACKED'},
        ),
      );
      await pumpEventQueue();
      expect(repo.data['session'], 'LEGACY-FLAT-VALUE');
    });

    test('a plugin cannot reach another plugin\'s preferences by naming '
        'it', () async {
      // What the settings screen writes for plugin A.
      repo.data['com.a:mirror'] = 'https://a.example';

      final tokenB = engine.mintBridgeToken(
        namespace: 'com_b__sub1',
        packageName: 'com.b',
      );

      engine.handleWorkerMessage(
        _bridgeMsg(
          bid: 1,
          channel: 'get_preference',
          args: {
            'id': 'b_peek',
            '__ssTok': tokenB,
            'packageName': 'com.a',
            'key': 'mirror',
          },
        ),
      );
      await pumpEventQueue();
      expect(
        worker.replyFor('b_peek'),
        isNull,
        reason: "plugin B read plugin A's configured mirror",
      );

      engine.handleWorkerMessage(
        _bridgeMsg(
          bid: 2,
          channel: 'set_preference',
          args: {
            '__ssTok': tokenB,
            'packageName': 'com.a',
            'key': 'mirror',
            'value': 'https://attacker.example',
          },
        ),
      );
      await pumpEventQueue();
      expect(
        repo.data['com.a:mirror'],
        'https://a.example',
        reason: "plugin B rewrote plugin A's base URL",
      );
      expect(repo.data['com.b:mirror'], 'https://attacker.example');
    });

    test('preferences stay under the reverse-DNS package name the settings '
        'screen uses', () async {
      final token = engine.mintBridgeToken(
        namespace: 'com_a__sub1',
        packageName: 'com.a',
      );
      repo.data['com.a:translation_type'] = 'dub';

      engine.handleWorkerMessage(
        _bridgeMsg(
          bid: 1,
          channel: 'get_preference',
          args: {'id': 'read', '__ssTok': token, 'key': 'translation_type'},
        ),
      );
      await pumpEventQueue();

      expect(worker.replyFor('read'), 'dub');
    });

    test('unloading a plugin revokes its token', () async {
      final token = engine.mintBridgeToken(
        namespace: 'com_a__sub1',
        packageName: 'com.a',
      );
      expect(engine.identityForToken(token), isNotNull);

      engine.unload('com_a__sub1');

      expect(engine.identityForToken(token), isNull);
    });
  });

  group('plugin HTTP is cancellable per invocation', () {
    test('abandoning a search cancels that plugin\'s in-flight request',
        () async {
      final token = engine.mintBridgeToken(
        namespace: 'com_a__sub1',
        packageName: 'com.a',
      );

      // Reproduce production id arithmetic: the plugin's script is loaded
      // before anything is invoked, so the engine's invoke counter and the
      // worker's callback counter are already one apart. The worker's first
      // callback is 'cb_0' while this invocation's id is 1.
      unawaited(engine.loadScript('/* wrapper */', tag: 'com.a'));
      await pumpEventQueue();
      engine.handleWorkerMessage(<String, dynamic>{'ld': 0});
      await pumpEventQueue();

      final searchCancel = CancelToken();
      final invoke = engine
          .invokeAsync('com_a__sub1.search', ['dune'], searchCancel)
          .catchError((Object _) => null);
      await pumpEventQueue();

      // The plugin fetches. The worker tags the bridge call with its own
      // most-recently-started callback id.
      engine.handleWorkerMessage(
        _bridgeMsg(
          bid: 1,
          channel: 'http_request',
          iid: 'cb_0',
          args: {
            'id': 'http_1',
            '__ssTok': token,
            'method': 'GET',
            'url': 'https://a.example/search?q=dune',
          },
        ),
      );
      await pumpEventQueue();

      expect(adapter.started, 1);
      expect(adapter.cancelled, 0);
      expect(worker.hasReplyFor('http_1'), isFalse);

      // The user retypes the query; the search is abandoned.
      searchCancel.cancel('user moved on');
      await pumpEventQueue();

      expect(
        adapter.cancelled,
        1,
        reason: 'the abandoned search left its HTTP request running',
      );

      // Let the invocation settle so no 90 s timeout timer is left behind.
      engine.handleWorkerMessage(<String, dynamic>{
        'ir': 1,
        'result': null,
        'err': null,
      });
      await invoke;
    });

    test('an invocation ending hangs up on the HTTP it left behind', () async {
      final token = engine.mintBridgeToken(
        namespace: 'com_a__sub1',
        packageName: 'com.a',
      );

      unawaited(engine.loadScript('/* wrapper */', tag: 'com.a'));
      await pumpEventQueue();
      engine.handleWorkerMessage(<String, dynamic>{'ld': 0});
      await pumpEventQueue();

      final invoke = engine
          .invokeAsync('com_a__sub1.search', ['dune'])
          .catchError((Object _) => null);
      await pumpEventQueue();

      engine.handleWorkerMessage(
        _bridgeMsg(
          bid: 1,
          channel: 'http_request',
          iid: 'cb_0',
          args: {
            'id': 'http_1',
            '__ssTok': token,
            'method': 'GET',
            'url': 'https://a.example/orphan',
          },
        ),
      );
      await pumpEventQueue();
      expect(adapter.cancelled, 0);

      // The plugin calls back without awaiting its own fetch.
      engine.handleWorkerMessage(<String, dynamic>{
        'ir': 1,
        'result': null,
        'err': null,
      });
      await invoke;
      await pumpEventQueue();

      expect(
        adapter.cancelled,
        1,
        reason: 'a finished invocation left a request on the wire',
      );
    });

    test('one plugin ending does not cancel another plugin\'s request',
        () async {
      final tokenA = engine.mintBridgeToken(
        namespace: 'com_a__sub1',
        packageName: 'com.a',
      );
      final tokenB = engine.mintBridgeToken(
        namespace: 'com_b__sub1',
        packageName: 'com.b',
      );

      unawaited(engine.loadScript('/* wrapper */', tag: 'com.a'));
      await pumpEventQueue();
      engine.handleWorkerMessage(<String, dynamic>{'ld': 0});
      await pumpEventQueue();

      final cancelA = CancelToken();
      final invokeA = engine
          .invokeAsync('com_a__sub1.search', ['dune'], cancelA)
          .catchError((Object _) => null);
      final invokeB = engine
          .invokeAsync('com_b__sub1.search', ['dune'])
          .catchError((Object _) => null);
      await pumpEventQueue();

      for (final entry in {'http_a': tokenA, 'http_b': tokenB}.entries) {
        engine.handleWorkerMessage(
          _bridgeMsg(
            bid: 1,
            channel: 'http_request',
            iid: 'cb_1',
            args: {
              'id': entry.key,
              '__ssTok': entry.value,
              'method': 'GET',
              'url': 'https://${entry.key}.example/',
            },
          ),
        );
      }
      await pumpEventQueue();
      expect(adapter.started, 2);

      cancelA.cancel('user moved on');
      await pumpEventQueue();

      expect(adapter.cancelled, 1, reason: 'cancelling A also cancelled B');

      engine.handleWorkerMessage(<String, dynamic>{
        'ir': 1,
        'result': null,
        'err': null,
      });
      engine.handleWorkerMessage(<String, dynamic>{
        'ir': 2,
        'result': null,
        'err': null,
      });
      await invokeA;
      await invokeB;
    });
  });

  group('the plugin wrapper carries the token', () {
    JsBasedProvider providerFor(String namespace) => JsBasedProvider(
      engine,
      '/tmp/does-not-need-to-exist.js',
      packageName: 'com.a',
      namespace: namespace,
    );

    test('the wrapper takes the token as an argument, not off a global', () {
      final iife = providerFor(
        'com_a__sub1',
      ).buildIife('function search(q, cb) { cb([]); }');

      expect(
        iife,
        contains('globalThis["__ssInstall_com_a__sub1"] = function(__ssTok)'),
      );
      expect(iife, contains('params.__ssTok = __ssTok;'));
      // A slot shared by every plugin is exactly what concurrent init
      // crosses: park A, park B, wrapper A, wrapper B.
      expect(
        iife,
        isNot(contains('globalThis.__ssBridgeToken')),
        reason: 'the token must not come from a slot shared between plugins',
      );
    });

    test('every storage and HTTP entry point in the wrapper is token-bound',
        () {
      final iife = providerFor('com_a__sub1').buildIife('// plugin');

      for (final call in [
        "__ssSend('get_preference'",
        "__ssSend('set_preference'",
        "__ssAsync('http_request'",
        "__ssAsync('http_parallel'",
      ]) {
        expect(iife, contains(call));
      }
      // The shared-global versions, which carry no identity, must not be the
      // ones the plugin body binds to.
      expect(iife, contains('const http_get = function'));
      expect(iife, contains('const http_post = function'));
    });

    test('the wrapper does not publish its identity-bearing helpers on '
        'globalThis', () {
      final iife = providerFor('com_a__sub1').buildIife('// plugin');

      expect(
        iife,
        isNot(contains('globalThis.getPreference =')),
        reason: 'the last plugin loaded would own every plugin\'s preferences',
      );
      expect(iife, isNot(contains('globalThis.setPreference =')));
    });

    test('the token itself is never baked into the cached wrapper', () {
      final token = engine.mintBridgeToken(
        namespace: 'com_a__sub1',
        packageName: 'com.a',
      );
      final iife = providerFor('com_a__sub1').buildIife('// plugin');

      expect(iife, isNot(contains(token)));
      // Same text on every run, or the compiled bytecode could never be
      // reused across launches.
      expect(iife, providerFor('com_a__sub1').buildIife('// plugin'));
    });
  });

  // Handing a plugin its token is two evals into one shared QuickJS runtime
  // with no lock between them, and the two are separated by a filesystem
  // await, so plugins initialising together interleave. These drive the real
  // JsBasedProvider._init() against the real worker; the concurrency, not the
  // test, decides the eval order.
  group('concurrent plugin init keeps identities apart', () {
    late _LiveEngine live;
    late Directory dir;

    setUp(() async {
      live = _LiveEngine(repo);
      dir = await Directory.systemTemp.createTemp('ss_bridge_tokens');
    });

    tearDown(() async {
      live.dispose();
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    /// A file-backed plugin — asset plugins skip the bytecode staleness check
    /// — whose only export writes [mark] into its own preferences.
    JsBasedProvider pluginWriting(
      String mark, {
      required String packageName,
      required String namespace,
    }) {
      final file = File('${dir.path}/$mark.js')
        ..writeAsStringSync(
          "function getSettings() { setPreference('who', '$mark'); return []; }",
        );
      return JsBasedProvider(
        live.engine,
        file.path,
        packageName: packageName,
        namespace: namespace,
      );
    }

    test('two plugins starting together each write to their own key space', () async {
      final a = pluginWriting(
        'A',
        packageName: 'com.a',
        namespace: 'com_a__sub1',
      );
      final b = pluginWriting(
        'B',
        packageName: 'com.b',
        namespace: 'com_b__sub1',
      );

      // The first search on a device with two plugins installed.
      await Future.wait<Object?>(<Future<Object?>>[
        a.getSettings(),
        b.getSettings(),
      ]);
      await pumpEventQueue();

      expect(
        repo.data['com.a:who'],
        'A',
        reason:
            'plugin A lost its own preference key space — either its calls '
            'were attributed to another plugin or they carried no token at '
            'all, so its saved settings vanish on every launch',
      );
      expect(
        repo.data['com.b:who'],
        'B',
        reason: 'plugin B lost its own preference key space',
      );
      // One plugin's data sitting in the other's key space.
      expect(repo.data['com.a:who'], isNot('B'));
      expect(repo.data['com.b:who'], isNot('A'));
    });

    // Bytecode is compiled after the first load, so the second and every
    // later launch on Android/Windows/Linux goes through `loadBytes` — a
    // separate place the token has to be handed over, because the wrapper
    // bytecode only publishes the installer and does not run the plugin body.
    //
    // The host runtime is JavaScriptCore, which has no bytecode support, so
    // this records what Dart sends the worker rather than running it.
    test('the bytecode fast path hands the plugin its token too', () async {
      final port = ReceivePort();
      final fastEngine = _RecordingEngine(repo, port.sendPort);
      addTearDown(() {
        fastEngine.dispose();
        port.close();
      });

      final js = File('${dir.path}/fast.js')
        ..writeAsStringSync('function getSettings() { return []; }');
      final provider = JsBasedProvider(
        fastEngine,
        js.path,
        packageName: 'com.a',
        namespace: 'com_a__sub1',
      );

      // A fresh .qbc from a previous launch, newer than the script.
      final qbc = File(provider.bytecodePath!)
        ..writeAsBytesSync(Uint8List.fromList(<int>[0, 1, 2, 3]));
      await qbc.setLastModified(DateTime.now().add(const Duration(minutes: 1)));

      await provider.waitForInit;

      expect(
        fastEngine.evals.map((e) => e.kind).toList(),
        <String>['bytes', 'script'],
        reason:
            'the bytecode fast path must load the wrapper and then run '
            'exactly one more eval, the token install — a leading script '
            'eval instead means the token went through a shared global '
            'again, and a missing one means the plugin body never ran',
      );

      final token = fastEngine.mintBridgeToken(
        namespace: 'com_a__sub1',
        packageName: 'com.a',
      );
      final install = fastEngine.evals.last.text;
      expect(install, contains('__ssInstall_com_a__sub1'));
      expect(
        install,
        contains(token),
        reason:
            'the installer must be called with this plugin\'s own token, '
            'passed as an argument',
      );
    });

    // Upgrading QuickJS changes its bytecode format, and the .qbc cache is
    // keyed on the wrapper text and the script's mtime - nothing that moves
    // when the engine does. Every cached file is then unreadable, and before
    // this fallback a plugin died on it: "CRITICAL - Eval failed ... invalid
    // version (19 expected=28)", observed on a device after the v0.9.0 ->
    // v0.17.0 sync. One slow load is the correct cost; a dead plugin is not.
    test('a .qbc the engine cannot read falls back to source, and is deleted',
        () async {
      final port = ReceivePort();
      final staleEngine = _StaleBytecodeEngine(repo, port.sendPort);
      addTearDown(() {
        staleEngine.dispose();
        port.close();
      });

      final js = File('${dir.path}/stale.js')
        ..writeAsStringSync('function getSettings() { return []; }');
      final provider = JsBasedProvider(
        staleEngine,
        js.path,
        packageName: 'com.a',
        namespace: 'com_a__sub1',
      );

      // Fresh by mtime, unreadable by content - what an engine upgrade leaves.
      final qbc = File(provider.bytecodePath!)
        ..writeAsBytesSync(Uint8List.fromList(<int>[0, 1, 2, 3]));
      await qbc.setLastModified(DateTime.now().add(const Duration(minutes: 1)));

      await provider.waitForInit;

      expect(
        staleEngine.evals.map((e) => e.kind).toList(),
        <String>['bytes', 'script', 'script'],
        reason: 'the failed bytecode load must be followed by the text path '
            'and then the token install, not abandoned',
      );
      expect(
        qbc.existsSync(),
        isFalse,
        reason: 'the unusable cache must be removed so the next launch '
            'recompiles instead of failing again',
      );
    });
  });

  // Every installed plugin evals into one QuickJS realm, so `sendMessage`,
  // `JSON` and `Object.prototype` are shared between all of them, and every
  // bridge call hands its capability token to those shared primitives on the
  // way out. A plugin that replaces one of them can read a later plugin's
  // token; `_identityFor` consults the token and nothing else, so with it the
  // attacker reads and overwrites the victim's stored credentials.
  //
  // These run two real JsBasedProviders on one real worker.
  group('a co-resident plugin cannot harvest another plugin\'s token', () {
    late _LiveEngine live;
    late Directory dir;

    setUp(() async {
      live = _LiveEngine(repo);
      dir = await Directory.systemTemp.createTemp('ss_hostile_plugin');
    });

    tearDown(() async {
      live.dispose();
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    JsBasedProvider plugin(
      String body, {
      required String name,
      required String packageName,
      required String namespace,
    }) {
      final file = File('${dir.path}/$name.js')..writeAsStringSync(body);
      return JsBasedProvider(
        live.engine,
        file.path,
        packageName: packageName,
        namespace: namespace,
      );
    }

    /// Everything after the hook is identical for each variant: replay every
    /// token seen so far as if it were ours, then record how many were
    /// captured, under our own legitimate preference key.
    String hostile(String hook) =>
        '''
        globalThis.__loot = [];
        $hook
        function getSettings() {
          var loot = globalThis.__loot.slice();
          for (var i = 0; i < loot.length; i++) {
            sendMessage('set_preference', JSON.stringify(
              { key: 'who', value: 'EVIL', __ssTok: loot[i] }));
          }
          setPreference('stolen', String(loot.length));
          return [];
        }
        ''';

    final Map<String, String> hooks = <String, String>{
      'replacing the sendMessage global': '''
        var __orig = sendMessage;
        try {
          globalThis.sendMessage = function (ch, json) {
            try {
              var p = JSON.parse(json);
              if (p && p.__ssTok) globalThis.__loot.push(p.__ssTok);
            } catch (e) {}
            return __orig(ch, json);
          };
        } catch (e) {}
      ''',
      'replacing JSON.stringify': '''
        var __str = JSON.stringify;
        try {
          JSON.stringify = function (v) {
            try {
              if (v && v.__ssTok) globalThis.__loot.push(v.__ssTok);
            } catch (e) {}
            return __str.apply(JSON, arguments);
          };
        } catch (e) {}
      ''',
      'an Object.prototype setter for the token field': '''
        try {
          Object.defineProperty(Object.prototype, '__ssTok', {
            configurable: true,
            enumerable: false,
            get: function () { return undefined; },
            set: function (v) {
              globalThis.__loot.push(v);
              Object.defineProperty(this, '__ssTok', {
                value: v, writable: true, enumerable: true, configurable: true
              });
            }
          });
        } catch (e) {}
      ''',
      'an Object.prototype toJSON hook': '''
        try {
          Object.prototype.toJSON = function () {
            var copy = {};
            for (var k in this) {
              if (Object.prototype.hasOwnProperty.call(this, k)) copy[k] = this[k];
            }
            if (copy.__ssTok) globalThis.__loot.push(copy.__ssTok);
            return copy;
          };
        } catch (e) {}
      ''',
    };

    for (final MapEntry<String, String> variant in hooks.entries) {
      test('by ${variant.key}', () async {
        // The hostile plugin loads first — install order is the user's, and
        // an attacker only has to be installed once.
        final JsBasedProvider evil = plugin(
          hostile(variant.value),
          name: 'evil',
          packageName: 'com.evil',
          namespace: 'com_evil__sub1',
        );
        await evil.waitForInit;

        // An ordinary plugin saves a setting of its own.
        final JsBasedProvider victim = plugin(
          "function getSettings() { setPreference('who', 'B'); return []; }",
          name: 'victim',
          packageName: 'com.b',
          namespace: 'com_b__sub1',
        );
        await victim.getSettings();
        await pumpEventQueue();

        // The next time the user opens the hostile plugin, it spends whatever
        // it captured.
        await evil.getSettings();
        await pumpEventQueue();

        expect(
          repo.data['com.evil:stolen'],
          '0',
          reason:
              'the hostile plugin read another plugin\'s capability token off '
              'a shared realm primitive — with it, every bridge call it makes '
              'is attributed to the victim',
        );
        expect(
          repo.data['com.b:who'],
          'B',
          reason:
              'one installed plugin overwrote another plugin\'s saved '
              'settings; the same token reads out that plugin\'s stored '
              'credentials and session tokens',
        );
      });
    }

    // The lockdown is on the realm every plugin shares, so it has to stay
    // invisible to plugins that are not attacking anyone. `toJSON` is pinned
    // as an accessor so that a plugin's own `toJSON` still installs and runs.
    test('but ordinary JavaScript is untouched by the lockdown', () async {
      final JsBasedProvider ordinary = plugin(
        '''
        function getSettings() {
          var o = { a: 1 };
          o.toJSON = function () { return { a: 2 }; };
          setPreference('own', JSON.stringify(o));
          setPreference('date', JSON.stringify({ d: new Date(0) }));
          setPreference('plain', JSON.stringify({ b: 3 }));
          return [];
        }
        ''',
        name: 'ordinary',
        packageName: 'com.c',
        namespace: 'com_c__sub1',
      );
      await ordinary.getSettings();
      await pumpEventQueue();

      expect(
        repo.data['com.c:own'],
        '{"a":2}',
        reason: 'a plugin\'s own toJSON must still be honoured',
      );
      expect(
        repo.data['com.c:date'],
        contains('1970-01-01'),
        reason: 'Date.prototype.toJSON must still shadow the pinned accessor',
      );
      expect(repo.data['com.c:plain'], '{"b":3}');
    });

    // The installer name is derived from the namespace, so it is public. A
    // non-configurable accessor squatted at that name captures the real
    // installer, hands back a trampoline and survives `delete`, and Dart then
    // passes the token straight to the attacker.
    test('by squatting the victim\'s installer slot on globalThis', () async {
      final JsBasedProvider evil = plugin(
        '''
        globalThis.__loot = [];
        try {
          var __real = null;
          Object.defineProperty(globalThis, '__ssInstall_com_b__sub1', {
            configurable: false,
            enumerable: false,
            set: function (f) { __real = f; },
            get: function () {
              return function (tok) {
                globalThis.__loot.push(tok);
                if (__real) __real(tok);
              };
            }
          });
        } catch (e) { globalThis.__loot.push('ERR:' + e); }
        function getSettings() {
          var loot = globalThis.__loot.slice();
          for (var i = 0; i < loot.length; i++) {
            sendMessage('set_preference', JSON.stringify(
              { key: 'who', value: 'EVIL', __ssTok: loot[i] }));
          }
          setPreference('stolen', String(loot.length));
          return [];
        }
        ''',
        name: 'evil2',
        packageName: 'com.evil',
        namespace: 'com_evil__sub1',
      );
      await evil.waitForInit;
      final JsBasedProvider victim = plugin(
        "function getSettings() { setPreference('who', 'B'); return []; }",
        name: 'victim2',
        packageName: 'com.b',
        namespace: 'com_b__sub1',
      );
      await victim.getSettings();
      await pumpEventQueue();
      await evil.getSettings();
      await pumpEventQueue();

      expect(
        repo.data['com.evil:stolen'],
        '0',
        reason:
            'Dart handed the victim\'s capability token to a trampoline the '
            'attacker had installed at the victim\'s installer name',
      );
      expect(
        repo.data['com.b:who'],
        isNot('EVIL'),
        reason:
            'with the stolen token the attacker writes into the victim\'s '
            'key space; a squatted slot must fail closed instead',
      );
    });

    // The worker cannot import js_engine.dart without an import cycle, so the
    // field it pins on Object.prototype is spelled out there. A rename of
    // kBridgeTokenField would silently leave the real field unpinned.
    test('the hardening pins the field name the bridge actually reads', () {
      expect(
        kBridgeHardeningJs,
        contains("'${JsEngineService.kBridgeTokenField}'"),
      );
    });
  });
}

/// One eval as Dart handed it to the worker.
class _Eval {
  _Eval(this.kind, this.text);
  final String kind; // 'script' | 'bytes'
  final String text;
}

/// A [JsEngineService] that records the evals plugin init sends instead of
/// running them. Real token minting, no worker.
class _RecordingEngine extends JsEngineService {
  _RecordingEngine(ExtensionRepository repo, SendPort port)
    : super.withWorkerPort(repo, Dio(), port);

  final List<_Eval> evals = <_Eval>[];

  @override
  Future<void> loadScript(String script, {String? tag}) async {
    evals.add(_Eval('script', script));
  }

  @override
  Future<void> loadBytes(Uint8List bytecode, {String? tag}) async {
    evals.add(_Eval('bytes', ''));
  }
}

/// A [_RecordingEngine] whose bytecode load fails exactly as QuickJS does when
/// the cached `.qbc` was written by a different engine version.
class _StaleBytecodeEngine extends _RecordingEngine {
  _StaleBytecodeEngine(super.repo, super.port);

  @override
  Future<void> loadBytes(Uint8List bytecode, {String? tag}) async {
    evals.add(_Eval('bytes', ''));
    throw Exception('JS Eval Error: SyntaxError: invalid version (19 expected=28)');
  }
}

/// Wires a real [JsWorkerRunner] to a real [JsEngineService] through a pair of
/// ports, so plugin init runs end to end: QuickJS evals in arrival order and
/// the bridge call that comes back carries the token the plugin really holds.
class _LiveEngine {
  _LiveEngine(ExtensionRepository repo) {
    _fromWorker.listen((Object? m) => engine.handleWorkerMessage(m));
    _runner = JsWorkerRunner(_fromWorker.sendPort);
    _toWorker.listen(_runner.handle);
    engine = JsEngineService.withWorkerPort(repo, Dio(), _toWorker.sendPort);
  }

  final ReceivePort _fromWorker = ReceivePort();
  final ReceivePort _toWorker = ReceivePort();
  late final JsWorkerRunner _runner;
  late final JsEngineService engine;

  void dispose() {
    _runner.handle(<String, Object?>{'dp': 1});
    engine.dispose();
    _fromWorker.close();
    _toWorker.close();
  }
}
