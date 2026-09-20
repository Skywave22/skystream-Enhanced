// Background-isolate QuickJS worker.
//
// Owns the JavascriptRuntime, eval queue, and job pump. Pure-compute bridges
// (base64, crypto, DOM, regex, JSON) are handled locally. IO-bound bridges
// (http_request, get_storage, set_storage, get_preference, set_preference,
// solve_captcha) are forwarded to the main isolate via SendPort and resolved
// asynchronously through the eval queue.
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter_js_ng/flutter_js.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as html_dom;
import 'package:pointycastle/export.dart';
import 'package:crypto/crypto.dart' as crypto_lib;
import 'aes_decrypt.dart';
import '../utils/js_unpacker.dart';

// ── Message type keys (short to minimise serialisation overhead) ─────────────

// Main → Worker
const _mLoadScript = 'ls'; // {ls:1, id:int, payload:String, tag:String?}
const _mLoadBytes = 'lb'; // {lb:1, id:int, payload:Uint8List, tag:String?}
const _mInvoke = 'iv'; // {iv:1, id:int, fn:String, aj:String}
const _mCancelInvoke = 'ci'; // {ci:1, id:int}
const _mCancelTag = 'ct'; // {ct:String}
const _mBridgeResp = 'br'; // {br:1, bid:int, jsId:String, rv:Object?, err:bool}
// The bridge result arrives unencoded and is serialised here rather than on
// the main isolate - see buildBridgeResponse in js_engine.dart.
const _kBridgeRespValue = 'rv';
const _mDispose = 'dp';
const _mGc = 'gc';
const _mUnload = 'ul'; // {ul: String namespace}

// Hard cap on a single JSON payload the worker will decode synchronously.
// jsonDecode is sync, so a 10 MB blob from a misbehaving plugin freezes this
// isolate for about a second.
const int _kMaxJsonInputBytes = 10 * 1024 * 1024;

// Worker → Main
const _mReady = 'rd'; // {rd:SendPort}
const _mLoadDone = 'ld'; // {ld:int}
const _mLoadErr = 'le'; // {le:int, msg:String}
const _mInvokeResult = 'ir'; // {ir:int, result:dynamic}
// _mInvokeErr ('ie') is sent inline in _mInvokeResult with a non-null 'err' field
const _mBridge = 'bg'; // {bg:1, bid:int, ch:String, aj:String, iid:String?}
const _mLog = 'll'; // {ll:String, err:bool}

// ── IO bridge channel names forwarded to main ────────────────────────────────
const _ioBridges = {
  'http_request',
  'http_parallel',
  'get_storage',
  'set_storage',
  'get_preference',
  'set_preference',
  'solve_captcha',
};

// ── Isolate entry point ───────────────────────────────────────────────────────

/// Top-level entry point for the background JS engine isolate.
/// [args] is `[mainSendPort, RootIsolateToken]`.
/// The token enables Flutter platform-channel access (asset bundle, etc.)
/// required by flutter_js's enableFetch() polyfill.
void jsEngineWorkerEntry(List<Object?> args) {
  final mainPort = args[0] as SendPort;
  final token = args[1] as RootIsolateToken;
  BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  final rx = ReceivePort();
  mainPort.send({_mReady: rx.sendPort});
  final runner = JsWorkerRunner(mainPort);
  rx.listen(runner.handle);
}

// ── Worker runner (lives in background isolate) ───────────────────────────────

/// The worker's message loop and QuickJS host. Constructed by
/// [jsEngineWorkerEntry] on the background isolate; exposed (rather than
/// private) so the engine tests can drive the real runtime in-process.
@visibleForTesting
class JsWorkerRunner {
  final SendPort _tx;
  late final JavascriptRuntime _rt;

  // Eval queue: (payload, completer?, tag?)
  final _q = <(Object, Completer<void>?, String?)>[];
  bool _draining = false;

  Timer? _pump;
  // Mirrors the mode of the live [_pump] timer. Never assigned outside
  // [_startPump]: the pump's desired mode is derived from [_inv], never
  // tracked by hand.
  bool _pumpFast = false;
  int _pumpTicks = 0;
  bool _disposed = false;
  int _cbCnt = 0;
  int _domCnt = 0;
  int _bridgeCnt = 0;

  // DOM node registry (doc and element stubs)
  final _dom = <String, dynamic>{};

  // invokeId → jsCallbackId (for routing js_dispatch_callback → main)
  final _inv = <int, String>{};
  // jsCallbackId → invokeId (reverse)
  final _cbInv = <String, int>{};

  // For HTTP cancel-token routing: the most-recently-started JS callback ID.
  String? _latestJsCbId;

  JsWorkerRunner(this._tx) {
    // xhr: false skips enableFetch(), which loads assets via rootBundle and so
    // needs ServicesBinding.instance - not available in a background isolate
    // even with BackgroundIsolateBinaryMessenger. The HTTP bridge below covers
    // every network request, so the fetch polyfill is not needed.
    _rt = getJavascriptRuntime(
      xhr: false,
      extraArgs: {
        'stackSize': 2 * 1024 * 1024,
        'memoryLimit': 256 * 1024 * 1024,
      },
    );
    _initBridges();
    _startPump(fast: false);
  }

  // ── Message dispatch ──────────────────────────────────────────────────────

  void handle(dynamic msg) {
    if (msg is! Map<dynamic, dynamic>) return;
    // Once torn down, stay torn down: a late message would restart the job
    // pump and, through the eval queue, make flutter_js resurrect a fresh
    // runtime after the main isolate had decided this worker was finished.
    if (_disposed) return;
    final m = msg;
    if (m.containsKey(_mLoadScript)) {
      _load(m['id'] as int, m['payload'] as String, m['tag'] as String?);
    } else if (m.containsKey(_mLoadBytes)) {
      _loadBytes(
        m['id'] as int,
        m['payload'] as Uint8List,
        m['tag'] as String?,
      );
    } else if (m.containsKey(_mInvoke)) {
      _invoke(m['id'] as int, m['fn'] as String, m['aj'] as String);
    } else if (m.containsKey(_mCancelInvoke)) {
      _cancelInvoke(m['id'] as int);
    } else if (m.containsKey(_mCancelTag)) {
      _cancelTag(m[_mCancelTag] as String);
    } else if (m.containsKey(_mBridgeResp)) {
      _bridgeResp(m);
    } else if (m.containsKey(_mDispose)) {
      _dispose();
    } else if (m.containsKey(_mGc)) {
      _rt.runGC();
    } else if (m.containsKey(_mUnload)) {
      _unload(m[_mUnload] as String);
    }
  }

  // ── Unload ────────────────────────────────────────────────────────────────
  //
  // Drops the plugin's exports off `globalThis` and runs GC. Each plugin's
  // IIFE wrapper assigns its API to `globalThis[namespace]` (see
  // js_based_provider._buildIife), so deleting that slot releases the closures
  // the plugin held. The runtime is shared, so this is not a full sandbox
  // teardown; it frees the per-plugin bytecode and closures for the next GC.
  void _unload(String namespace) {
    if (namespace.isEmpty) return;
    try {
      // Use bracket access + try/catch to avoid runtime errors when the
      // slot doesn't exist (idempotent on re-unload).
      _rt.evaluate(
        "try { delete globalThis[${jsonEncode(namespace)}]; } catch(e) {}",
      );
      _rt.runGC();
    } catch (e) {
      _tx.send({_mLog: 'unload($namespace) failed: $e', 'err': true});
    }
  }

  // ── Load ──────────────────────────────────────────────────────────────────

  void _load(int id, String script, String? tag) {
    final c = Completer<void>();
    _q.add((script, c, tag));
    _kickDrain();
    c.future.then(
      (_) => _tx.send({_mLoadDone: id}),
      onError: (Object e) => _tx.send({_mLoadErr: id, 'msg': e.toString()}),
    );
  }

  void _loadBytes(int id, Uint8List bytes, String? tag) {
    final c = Completer<void>();
    _q.add((bytes, c, tag));
    _kickDrain();
    c.future.then(
      (_) => _tx.send({_mLoadDone: id}),
      onError: (Object e) => _tx.send({_mLoadErr: id, 'msg': e.toString()}),
    );
  }

  // ── Invoke ────────────────────────────────────────────────────────────────

  void _invoke(int id, String fn, String argsJson) {
    final jsCbId = 'cb_${_cbCnt++}';
    _inv[id] = jsCbId;
    _cbInv[jsCbId] = id;
    _latestJsCbId = jsCbId;
    _syncPump();

    final wrapper =
        '''
      (function() {
        try {
          var dart_cb = function(res) {
            executeCallback('$jsCbId', res !== undefined ? res : "__dart_void__", null);
          };
          var fn = globalThis['$fn'];
          if (typeof fn !== 'function') {
            var parts = '$fn'.split('.');
            var target = globalThis;
            for (var i = 0; i < parts.length; i++) { target = target[parts[i]]; }
            fn = target;
          }
          if (typeof fn !== 'function') throw "Function $fn not found";
          var args = $argsJson;
          args.push(dart_cb);
          var res = fn.apply(null, args);
          if (res && (typeof res.then === 'function' || res instanceof Promise)) {
            res.then(dart_cb).catch(function(err) {
              executeCallback('$jsCbId', null, err.toString());
            });
          } else if (res !== undefined) {
            dart_cb(res);
          }
        } catch(e) {
          executeCallback('$jsCbId', null, e.toString());
        }
      })();
    ''';
    _scheduleEval(wrapper);
  }

  void _cancelInvoke(int id) {
    final jsCbId = _inv.remove(id);
    if (jsCbId != null) _cbInv.remove(jsCbId);
    // The invoke is gone whether or not its JS callback ever fires, so the
    // pump must be re-derived here too. This is the path the main isolate's
    // 90 s timeout takes; without it the 16 ms pump runs for the life of the
    // process.
    _syncPump();
  }

  void _cancelTag(String tag) {
    final cancelled = _q.where((e) => e.$3 == tag).toList();
    _q.removeWhere((e) => e.$3 == tag);
    for (final entry in cancelled) {
      entry.$2?.completeError(Exception('cancelled'));
    }
  }

  // ── Bridge response from main ─────────────────────────────────────────────

  void _bridgeResp(Map<dynamic, dynamic> m) {
    final jsId = m['jsId'] as String?;
    if (jsId == null) return;
    final isError = m['err'] as bool? ?? false;
    // jsonEncode runs here, on the worker isolate: a plugin that scrapes a
    // multi-MB page must not charge that encode to the UI isolate.
    String resultJson;
    try {
      resultJson = jsonEncode(m[_kBridgeRespValue]);
    } catch (e) {
      resultJson = jsonEncode('bridge result not encodable: $e');
    }
    _scheduleEval("_resolveDartAsync('$jsId', $resultJson, $isError)");
  }

  // ── Eval queue ────────────────────────────────────────────────────────────

  void _scheduleEval(String script) {
    _q.add((script, null, null));
    _kickDrain();
  }

  void _kickDrain() {
    if (!_draining) {
      _draining = true;
      Future.delayed(Duration.zero, _drain);
    }
  }

  void _drain() {
    if (_q.isEmpty) {
      _draining = false;
      return;
    }
    final (payload, completer, _) = _q.removeAt(0);
    final res = payload is Uint8List
        ? _rt.evalBytes(payload)
        : _rt.evaluate(payload as String);
    if (completer != null) {
      if (res.isError) {
        completer.completeError(
          Exception('JS Eval Error: ${res.stringResult}'),
        );
      } else {
        completer.complete();
      }
    }
    Future.delayed(Duration.zero, _drain);
  }

  // ── JS job pump ───────────────────────────────────────────────────────────

  void _startPump({bool fast = false}) {
    _pump?.cancel();
    _pumpFast = fast;
    if (fast) {
      _pump = Timer.periodic(const Duration(milliseconds: 16), (_) {
        _pumpTicks++;
        for (int i = 0; i < 8; i++) {
          _rt.executePendingJob();
        }
      });
    } else {
      _pump = Timer.periodic(const Duration(seconds: 1), (_) {
        _pumpTicks++;
        _rt.executePendingJob();
      });
    }
  }

  /// Re-derives the pump mode from the set of in-flight invokes.
  ///
  /// The pump runs fast (16 ms × 8 jobs) exactly while at least one invoke is
  /// waiting on its JS callback, and idles at 1 Hz otherwise. Deriving the
  /// mode from [_inv] rather than from a hand-maintained counter is what keeps
  /// it honest in both directions: a cancelled invoke cannot pin the fast pump
  /// forever, a callback dispatched twice cannot strand every later invoke at
  /// 1 Hz, and calling this twice is a no-op.
  void _syncPump() {
    final fast = _inv.isNotEmpty;
    if (_pump != null && fast == _pumpFast) return;
    _startPump(fast: fast);
  }

  /// Number of invokes waiting on their JS callback. The pump runs fast iff
  /// this is non-zero.
  @visibleForTesting
  int get inFlightInvokes => _inv.length;

  /// Pump ticks since the worker started. Each fast tick is eight
  /// `executePendingJob` FFI calls, so this measures wasted work.
  @visibleForTesting
  int get pumpTicks => _pumpTicks;

  /// Whether the 16 ms job pump is running. See [_syncPump].
  @visibleForTesting
  bool get isPumpFast => _pumpFast;

  // ── Dispose ───────────────────────────────────────────────────────────────

  void _dispose() {
    _disposed = true;
    _pump?.cancel();
    _pump = null;
    for (final entry in _q) {
      entry.$2?.completeError(Exception('disposed'));
    }
    _q.clear();
    _dom.clear();
    _inv.clear();
    _cbInv.clear();
    try {
      _rt.dispose();
    } catch (_) {}
  }

  // ── Bridge registrations ──────────────────────────────────────────────────

  void _initBridges() {
    // ── Callback dispatcher (resolves invokeAsync on main) ─────────────────
    _rt.onMessage('js_dispatch_callback', (dynamic args) {
      try {
        final data = _toMap(args);
        final jsCbId = data['callbackId'] as String?;
        if (jsCbId == null) return null;
        // A callback id can be dispatched twice: the invoke wrapper passes
        // dart_cb as the last argument and also chains it onto a returned
        // promise, so a plugin using both conventions fires it twice. The
        // second dispatch finds nothing to retire.
        final invId = _cbInv.remove(jsCbId);
        if (invId != null) {
          _inv.remove(invId);
          _syncPump();
          _tx.send({
            _mInvokeResult: invId,
            'result': data['result'],
            'err': data['error'],
          });
        }
      } catch (e) {
        _txLog('[dispatch error] $e', err: true);
      }
      return null;
    });

    // ── setTimeout/setInterval bridge ──────────────────────────────────────
    _rt.onMessage('js_set_timeout', (dynamic args) {
      try {
        final data = _toMap(args);
        final id = data['id'] as String?;
        final delay = (data['delay'] as num?)?.toInt() ?? 0;
        if (id != null) {
          Future.delayed(Duration(milliseconds: delay), () {
            _scheduleEval(
              "if (globalThis.timeout_registry['$id']) { globalThis.timeout_registry['$id'](); }",
            );
          });
        }
      } catch (e) {
        _txLog('[timer error] $e', err: true);
      }
      return null;
    });

    // ── Console ────────────────────────────────────────────────────────────
    _rt.onMessage('console_log', (dynamic args) {
      _txLog(_sanitize(args));
      return null;
    });
    _rt.onMessage('console_error', (dynamic args) {
      _txLog(_sanitize(args), err: true);
      return null;
    });

    // ── IO bridges forwarded to main ───────────────────────────────────────
    for (final channel in _ioBridges) {
      final ch = channel; // capture
      _rt.onMessage(ch, (dynamic args) {
        final bid = _bridgeCnt++;
        final argsMap = args is Map
            ? Map<String, dynamic>.from(args)
            : _toMap(args);
        _tx.send({
          _mBridge: 1,
          'bid': bid,
          'ch': ch,
          'aj': jsonEncode(argsMap),
          'iid': _latestJsCbId,
        });
        return null;
      });
    }

    // ── Base64 ────────────────────────────────────────────────────────────
    _rt.onMessage('base64_decode', (dynamic args) {
      try {
        return utf8.decode(base64.decode(args.toString()));
      } catch (_) {
        return null;
      }
    });
    _rt.onMessage('base64_encode', (dynamic args) {
      try {
        return base64.encode(utf8.encode(args.toString()));
      } catch (_) {
        return null;
      }
    });

    // ── DOM ────────────────────────────────────────────────────────────────
    _rt.onMessage('dom_parse', (dynamic args) {
      final data = _toMap(args);
      final callbackId = data['id'] as String?;
      final html = (data['html'] as String?) ?? '';
      Future.microtask(() {
        final id = 'doc_${_domCnt++}';
        if (_dom.length > 100) {
          final keys = _dom.keys.toList();
          for (int i = 0; i < _dom.length - 50 && i < keys.length; i++) {
            _dom.remove(keys[i]);
          }
        }
        _dom[id] = html_parser.parse(html);
        if (callbackId != null) {
          _scheduleEval(
            "_resolveDartAsync('$callbackId', ${jsonEncode(id)}, false)",
          );
        }
      });
      return null;
    });

    _rt.onMessage('dom_query', (dynamic args) {
      try {
        final data = _toMap(args);
        final nodeId = data['nodeId'] as String?;
        final query = data['query'] as String?;
        final multi = data['multi'] as bool? ?? false;
        if (nodeId == null || query == null) return null;
        final node = _dom[nodeId];
        if (node == null) return null;
        if (multi) {
          return _querySelectorAll(node, query).map(_serializeElement).toList();
        }
        final results = _querySelectorAll(node, query);
        return results.isNotEmpty ? _serializeElement(results.first) : null;
      } catch (_) {
        return null;
      }
    });

    _rt.onMessage('dom_dispose', (dynamic args) {
      _dom.remove(args.toString());
      return 'OK';
    });

    _rt.onMessage('dom_query_batch', (dynamic args) {
      try {
        final data = _toMap(args);
        final nodeId = data['nodeId'] as String?;
        final queries = (data['queries'] as List?) ?? [];
        if (nodeId == null) return null;
        final node = _dom[nodeId];
        if (node == null) return null;
        return queries.map((q) {
          final qm = q is Map ? Map<String, dynamic>.from(q) : _toMap(q);
          final selector = qm['query'] as String? ?? '*';
          final attr = qm['attr'] as String? ?? 'textContent';
          final first = qm['first'] as bool? ?? false;
          final elems = _querySelectorAll(node, selector);
          if (first) {
            return elems.isEmpty ? null : _extractAttr(elems.first, attr);
          }
          return elems.map((e) => _extractAttr(e, attr)).toList();
        }).toList();
      } catch (_) {
        return null;
      }
    });

    _rt.onMessage('dom_parse_and_extract', (dynamic args) {
      final data = _toMap(args);
      final callbackId = data['id'] as String?;
      final html = (data['html'] as String?) ?? '';
      final extractionMap = Map<String, dynamic>.from(
        (data['extract'] as Map?) ?? {},
      );
      Future.microtask(() {
        try {
          final result = _parseAndExtract(html, extractionMap);
          if (callbackId != null) {
            _scheduleEval(
              "_resolveDartAsync('$callbackId', ${jsonEncode(result)}, false)",
            );
          }
        } catch (e) {
          if (callbackId != null) {
            _scheduleEval(
              "_resolveDartAsync('$callbackId', ${jsonEncode(e.toString())}, true)",
            );
          }
        }
      });
      return null;
    });

    // ── Regex ──────────────────────────────────────────────────────────────
    _rt.onMessage('regex_match_all', (dynamic args) {
      try {
        final data = _toMap(args);
        final text = (data['text'] as String?) ?? '';
        final pattern = (data['pattern'] as String?) ?? '';
        final group = (data['group'] as int?) ?? 0;
        final cs = data['caseSensitive'] as bool? ?? true;
        final regex = RegExp(pattern, caseSensitive: cs);
        return regex
            .allMatches(text)
            .map<String?>((m) => m.group(group))
            .whereType<String>()
            .toList();
      } catch (_) {
        return <String>[];
      }
    });

    // ── JSON extract ───────────────────────────────────────────────────────
    _rt.onMessage('json_extract', (dynamic args) {
      try {
        final data = _toMap(args);
        final jsonStr = (data['json'] as String?) ?? '{}';
        final paths = (data['paths'] as List?) ?? [];
        // Bound input: jsonDecode is synchronous on this isolate.
        if (jsonStr.length > _kMaxJsonInputBytes) {
          return null;
        }
        final parsed = jsonDecode(jsonStr);
        final result = <String, dynamic>{};
        for (final path in paths) {
          final key = path.toString();
          result[key] = _extractJsonPath(parsed, key);
        }
        return result;
      } catch (_) {
        return null;
      }
    });

    // ── Crypto ────────────────────────────────────────────────────────────
    _rt.onMessage('crypto_md5', (dynamic args) {
      try {
        return crypto_lib.md5.convert(utf8.encode(args.toString())).toString();
      } catch (_) {
        return null;
      }
    });

    _rt.onMessage('crypto_sha256', (dynamic args) {
      try {
        return crypto_lib.sha256
            .convert(utf8.encode(args.toString()))
            .toString();
      } catch (_) {
        return null;
      }
    });

    _rt.onMessage('crypto_decrypt_aes', (dynamic args) {
      final data = _toMap(args);
      final callbackId = data['id'] as String?;
      try {
        final decrypted = aesDecryptBase64(
          key: data['key'] as String,
          iv: data['iv'] as String,
          data: data['data'] as String,
          mode: data['mode'] as String? ?? 'cbc',
        );
        if (callbackId != null) {
          _scheduleEval(
            "_resolveDartAsync('$callbackId', ${jsonEncode(decrypted)}, false)",
          );
        }
      } catch (e) {
        if (callbackId != null) {
          final msg = e is FormatException
              ? 'Invalid base64 format'
              : e.toString();
          _scheduleEval(
            "_resolveDartAsync('$callbackId', ${jsonEncode(msg)}, true)",
          );
        }
      }
      return null;
    });

    _rt.onMessage('crypto_pbkdf2', (dynamic args) {
      final data = _toMap(args);
      final callbackId = data['id'] as String?;
      try {
        final password = data['password'] as String;
        final salt = base64Decode(data['salt'] as String);
        final iterations = (data['iterations'] as int?) ?? 10000;
        final keyLen = (data['keyLength'] as int?) ?? 32;
        final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
          ..init(Pbkdf2Parameters(salt, iterations, keyLen));
        final result = derivator.process(
          Uint8List.fromList(utf8.encode(password)),
        );
        final b64 = base64Encode(result);
        if (callbackId != null) {
          _scheduleEval(
            "_resolveDartAsync('$callbackId', ${jsonEncode(b64)}, false)",
          );
        }
      } catch (e) {
        if (callbackId != null) {
          _scheduleEval(
            "_resolveDartAsync('$callbackId', ${jsonEncode(e.toString())}, true)",
          );
        }
      }
      return null;
    });

    _rt.onMessage('js_unpack', (dynamic args) {
      try {
        final jsStr = args.toString();
        return DartJsUnpacker(jsStr).unpack() ?? jsStr;
      } catch (_) {
        return args.toString();
      }
    });

    _rt.onMessage('parse_html', (dynamic args) {
      final data = _toMap(args);
      final callbackId = data['id'] as String?;
      final htmlStr = data['html'] as String? ?? '';
      final selector = data['selector'] as String? ?? '*';
      final attr = data['attr'] as String?;

      Future.microtask(() {
        try {
          final doc = html_parser.parse(htmlStr);
          final elems = doc.querySelectorAll(selector);
          final result = elems
              .map(
                (el) => {
                  'text': el.text,
                  'html': el.innerHtml,
                  'attr': attr != null ? (_extractAttr(el, attr) ?? '') : '',
                },
              )
              .toList();

          if (callbackId != null) {
            _scheduleEval(
              "_resolveDartAsync('$callbackId', ${jsonEncode(result)}, false)",
            );
          }
        } catch (e) {
          if (callbackId != null) {
            _scheduleEval(
              "_resolveDartAsync('$callbackId', ${jsonEncode(e.toString())}, true)",
            );
          }
        }
      });
      return null;
    });

    // ── polyfills + standard entities ─────────────────────────────────────
    _evalPolyfill('polyfill', _kPolyfillJs);
    _evalPolyfill('timer', _kTimerJs);
    _evalPolyfill('entities', _kEntitiesJs);
    // Must run last, and before any plugin: it seals the globals the three
    // above just installed. See [kBridgeHardeningJs].
    _evalPolyfill('bridge-hardening', kBridgeHardeningJs);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _txLog(String msg, {bool err = false}) {
    _tx.send({_mLog: msg, 'err': err});
  }

  void _evalPolyfill(String name, String js) {
    final res = _rt.evaluate(js);
    if (res.isError) {
      _txLog('Polyfill "$name" failed: ${res.stringResult}', err: true);
    }
  }

  static Map<String, dynamic> _toMap(dynamic args) {
    if (args is Map) return Map<String, dynamic>.from(args);
    final s = args.toString();
    // Bound bridge-call payloads. An empty map lets downstream handlers fall
    // back on their missing-key paths rather than freezing the isolate on
    // jsonDecode.
    if (s.length > _kMaxJsonInputBytes) {
      return const <String, dynamic>{};
    }
    return Map<String, dynamic>.from(jsonDecode(s) as Map);
  }

  static String _sanitize(dynamic args) {
    final msg = args.toString();
    if (msg.length > 500 &&
        (msg.toLowerCase().contains('<!doctype html>') ||
            msg.toLowerCase().contains('<html') ||
            msg.contains('</div>'))) {
      return '[HTML Content Omitted - Length: ${msg.length}]';
    }
    return msg.length > 3000 ? '${msg.substring(0, 3000)}... [Truncated]' : msg;
  }

  // ── DOM helpers ───────────────────────────────────────────────────────────

  List<html_dom.Element> _querySelectorAll(dynamic node, String query) {
    if (!query.contains(':contains(')) {
      return node is html_dom.Document
          ? node.querySelectorAll(query)
          : (node as html_dom.Element).querySelectorAll(query);
    }
    final rx = RegExp(r'(.*):contains\((.*)\)(.*)');
    final m = rx.firstMatch(query);
    if (m == null) {
      return node is html_dom.Document
          ? node.querySelectorAll(query)
          : (node as html_dom.Element).querySelectorAll(query);
    }
    final base = m.group(1) ?? '';
    final text = m.group(2) ?? '';
    final rest = m.group(3) ?? '';
    List<html_dom.Element> elems;
    if (base.trim().isEmpty) {
      elems = node is html_dom.Document
          ? node.querySelectorAll('*')
          : (node as html_dom.Element).querySelectorAll('*');
    } else {
      elems = node is html_dom.Document
          ? node.querySelectorAll(base)
          : (node as html_dom.Element).querySelectorAll(base);
    }
    final filtered = elems.where((e) => e.text.contains(text)).toList();
    if (rest.isNotEmpty) {
      return filtered.expand((e) => _querySelectorAll(e, rest)).toList();
    }
    return filtered;
  }

  Map<String, dynamic>? _serializeElement(html_dom.Element? el) {
    if (el == null) return null;
    final nodeId = 'node_${_domCnt++}';
    _dom[nodeId] = el;
    return {
      'nodeId': nodeId,
      'tagName': el.localName,
      'attributes': el.attributes.map((k, v) => MapEntry(k.toString(), v)),
      'textContent': el.text,
      'innerHTML': el.innerHtml,
      'outerHTML': el.outerHtml,
    };
  }

  static String? _extractAttr(html_dom.Element el, String attr) {
    switch (attr) {
      case 'textContent':
        return el.text;
      case 'innerHTML':
        return el.innerHtml;
      case 'outerHTML':
        return el.outerHtml;
      case 'tagName':
        return el.localName;
      case 'className':
        return el.className;
      default:
        return el.attributes[attr];
    }
  }

  static Map<String, dynamic> _parseAndExtract(
    String html,
    Map<String, dynamic> extractionMap,
  ) {
    final doc = html_parser.parse(html);
    final result = <String, dynamic>{};
    for (final entry in extractionMap.entries) {
      final spec = entry.value is Map
          ? Map<String, dynamic>.from(entry.value as Map)
          : <String, dynamic>{};
      final selector = (spec['query'] as String?) ?? '*';
      final attr = (spec['attr'] as String?) ?? 'textContent';
      final first = (spec['first'] as bool?) ?? false;
      final elems = doc.querySelectorAll(selector);
      result[entry.key] = first
          ? (elems.isEmpty ? null : _extractAttr(elems.first, attr))
          : elems.map((e) => _extractAttr(e, attr)).toList();
    }
    return result;
  }

  static dynamic _extractJsonPath(dynamic obj, String path) {
    final parts = path.split('.');
    dynamic cur = obj;
    for (final part in parts) {
      if (cur == null) return null;
      if (part.endsWith('[*]')) {
        final key = part.substring(0, part.length - 3);
        if (key.isNotEmpty && cur is Map) cur = cur[key];
        if (cur is List) {
          final rem = parts.sublist(parts.indexOf(part) + 1).join('.');
          if (rem.isEmpty) return cur;
          return cur.map((i) => _extractJsonPath(i, rem)).toList();
        }
        return null;
      }
      final idx = RegExp(r'^(.+)\[(\d+)\]$').firstMatch(part);
      if (idx != null) {
        final key = idx.group(1)!;
        final i = int.parse(idx.group(2)!);
        if (cur is Map) cur = cur[key];
        if (cur is List && i < cur.length) {
          cur = cur[i];
        } else {
          return null;
        }
        continue;
      }
      if (cur is Map) {
        cur = cur[part];
      } else {
        return null;
      }
    }
    return cur;
  }
}

// ── Static JS polyfill strings ────────────────────────────────────────────────

const _kPolyfillJs = r"""
  var global = globalThis;
  var console = {
    log:  function(msg) { sendMessage('console_log',   JSON.stringify(msg)); },
    error:function(msg) { sendMessage('console_error', JSON.stringify(msg)); },
    warn: function(msg) { sendMessage('console_log', "WARN: " + JSON.stringify(msg)); }
  };
  function log(msg) { console.log(msg); }

  globalThis.executeCallback = function(id, result, error) {
    sendMessage('js_dispatch_callback', JSON.stringify({
      callbackId: id, result: result, error: error
    }));
  };

  const _dartAsyncRegistry = {};
  globalThis._resolveDartAsync = function(id, result, isError) {
    const cb = _dartAsyncRegistry[id];
    if (cb) {
      delete _dartAsyncRegistry[id];
      if (isError) cb.reject(result);
      else cb.resolve(result);
    }
  };

  function _dartAsyncCall(messageId, params) {
    return new Promise((resolve, reject) => {
      const id = "async_" + Math.random().toString(36).substr(2, 9);
      _dartAsyncRegistry[id] = { resolve, reject };
      sendMessage(messageId, JSON.stringify({ id: id, ...params }));
    });
  }

  function _dartHttp(method, url, headers, body) {
    if (method === 'POST' && typeof headers === 'object' && headers !== null && !body && (headers.body || headers.headers)) {
      body = headers.body; headers = headers.headers;
    }
    return _dartAsyncCall('http_request', { method, url, headers: headers || {}, body });
  }

  function _createHybridResponse(res) {
    if (typeof res !== 'object' || res === null) return res;
    var hybrid = new String(res.body || "");
    Object.defineProperty(hybrid, 'status',     { value: res.status,    enumerable: false });
    Object.defineProperty(hybrid, 'statusCode', { value: res.status,    enumerable: false });
    Object.defineProperty(hybrid, 'body',       { value: res.body,      enumerable: false });
    Object.defineProperty(hybrid, 'headers',    { value: res.headers,   enumerable: false });
    return hybrid;
  }

  globalThis.http_get = function(url, headers, cb) {
    return _dartHttp('GET', url, headers, null).then(function(res) {
      if (cb && typeof cb === 'function') cb(res);
      return res;
    });
  };
  globalThis.http_post = function(url, headers, body, cb) {
    return _dartHttp('POST', url, headers, body).then(function(res) {
      if (cb && typeof cb === 'function') cb(res);
      return res;
    });
  };
  globalThis.http_parallel = function(requests) {
    return _dartAsyncCall('http_parallel', { requests: requests });
  };
  globalThis.getAndUnpack = function(js) {
    return sendMessage('js_unpack', js);
  };
  globalThis.parse_html = function(html, selector, attr) {
    return _dartAsyncCall('parse_html', { html: html, selector: selector, attr: attr });
  };
  async function _fetch(url) { return await http_get(url, {}); }
""";

/// Seals the shared-realm primitives a plugin's bridge calls pass through.
///
/// Every installed plugin evals into one [JavascriptRuntime]: one realm, one
/// `globalThis`. A plugin is attributed by a capability token that Dart mints
/// per plugin and hands to that plugin's wrapper closure
/// (`JsBasedProvider._installBridgeToken`), and the bridge consults that token
/// and nothing else (`JsEngineService._identityFor`). The token stays private
/// to the closure, but every bridge call hands it to shared primitives on the
/// way out:
///
///     params.__ssTok = __ssTok;                     // Object.prototype
///     sendMessage(channel, JSON.stringify(params)); // two globals
///
/// So a plugin that loads first could read every later plugin's token by
/// replacing `sendMessage` or `JSON.stringify`, or by installing an
/// `Object.prototype` setter for the token field or an `Object.prototype`
/// `toJSON` hook, and with a stolen token it is that plugin at the bridge.
/// Third-party plugins from an untrusted repository are the threat model.
///
/// This runs once, after the polyfills and before any plugin script, and
/// closes those four interception points:
///
///  * the bridge entry points (`sendMessage`, `_dartAsyncCall`) and the two
///    functions that carry bridge results back into a plugin
///    (`_resolveDartAsync`, `executeCallback`) become non-writable,
///    non-configurable globals. A plugin's `globalThis.sendMessage = ...` is
///    then a silent no-op in sloppy mode, which is how plugin scripts run;
///  * `JSON` and `JSON.stringify` likewise, since the token is serialised
///    through them. `JSON.parse` is deliberately left alone: nothing on the
///    token path calls it, and it is the more commonly re-polyfilled of the
///    two;
///  * `__ssTok` is pre-defined on `Object.prototype` as a non-configurable
///    data property, so it cannot be redefined as an accessor. It stays
///    writable, so `params.__ssTok = ...` still creates an own property on
///    the payload, and it is non-enumerable so it never appears in anyone's
///    serialised output;
///  * `toJSON` is pre-defined on `Object.prototype` as a non-configurable
///    accessor whose getter answers `undefined` (so `JSON.stringify` behaves
///    as if it were absent) and whose setter still installs an own `toJSON`
///    on any object other than `Object.prototype` itself. That keeps the one
///    legitimate use (`obj.toJSON = fn`) working while closing the
///    prototype-wide hook.
///
/// This is lockdown of a shared realm, not a sandbox: a plugin can still
/// clobber globals nothing trusted depends on. What it guarantees is that a
/// token handed to a plugin cannot be read by a co-resident one.
///
/// The `'__ssTok'` literal below must stay equal to
/// `JsEngineService.kBridgeTokenField`; the worker cannot import js_engine.dart
/// without an import cycle, so a test asserts the two agree.
@visibleForTesting
const String kBridgeHardeningJs = r"""
(function () {
  // Never change `enumerable` here: a function declaration creates a
  // non-configurable global property, and altering enumerable on one throws.
  var seal = function (holder, name) {
    try {
      var v = holder[name];
      if (typeof v === 'undefined') return;
      Object.defineProperty(holder, name, {
        value: v,
        writable: false,
        configurable: false
      });
    } catch (e) {}
  };

  seal(globalThis, 'sendMessage');
  seal(globalThis, '_dartAsyncCall');
  seal(globalThis, '_resolveDartAsync');
  seal(globalThis, 'executeCallback');
  seal(globalThis, 'JSON');
  seal(JSON, 'stringify');

  try {
    Object.defineProperty(Object.prototype, '__ssTok', {
      value: undefined,
      writable: true,
      enumerable: false,
      configurable: false
    });
  } catch (e) {}

  try {
    Object.defineProperty(Object.prototype, 'toJSON', {
      enumerable: false,
      configurable: false,
      get: function () { return undefined; },
      set: function (v) {
        if (this === Object.prototype || this === null || this === undefined) {
          return;
        }
        Object.defineProperty(this, 'toJSON', {
          value: v,
          writable: true,
          enumerable: true,
          configurable: true
        });
      }
    });
  } catch (e) {}
})();
""";

const _kTimerJs = r"""
  globalThis.timeout_registry = {};

  function setTimeout(callback, delay) {
    var id = "t_" + Date.now() + "_" + Math.random().toString(36).substr(2, 9);
    globalThis.timeout_registry[id] = function() {
      if (!globalThis.timeout_registry[id]) return;
      delete globalThis.timeout_registry[id];
      try { callback(); } catch (e) { console.error('Timeout error:', e); }
    };
    sendMessage('js_set_timeout', JSON.stringify({ id: id, delay: delay || 0 }));
    return id;
  }
  function clearTimeout(id) { if (id) delete globalThis.timeout_registry[id]; }
  function setInterval(cb, d) {
    var id = "i_" + Date.now() + "_" + Math.random().toString(36).substr(2, 9);
    var wrapper = function() {
      if (!globalThis.timeout_registry[id]) return;
      try { cb(); } catch (e) { console.error('Interval error:', e); }
      if (globalThis.timeout_registry[id]) {
        sendMessage('js_set_timeout', JSON.stringify({ id: id, delay: d || 0 }));
      }
    };
    globalThis.timeout_registry[id] = wrapper;
    sendMessage('js_set_timeout', JSON.stringify({ id: id, delay: d || 0 }));
    return id;
  }
  function clearInterval(id) { clearTimeout(id); }

  function setPreference(key, value) {
    sendMessage('set_storage', JSON.stringify({ key: key, value: value }));
  }
  function getPreference(key) {
    return _dartAsyncCall('get_storage', { key: key });
  }
""";

const _kEntitiesJs = r"""
  class Actor    { constructor(p) { Object.assign(this, p); } }
  class Trailer  { constructor(p) { Object.assign(this, p); } }
  class NextAiring { constructor(p) { Object.assign(this, p); } }

  class MultimediaItem {
    constructor(params) {
      Object.assign(this, {
        type: 'movie', status: 'ongoing', playbackPolicy: 'none',
        isAdult: false, streams: [], syncData: {}, ...params
      });
    }
  }
  class Episode {
    constructor(params) {
      Object.assign(this, {
        season: 0, episode: 0, dubStatus: 'none', playbackPolicy: 'none',
        streams: [], ...params
      });
    }
  }
  class StreamResult {
    constructor({ url, source, headers, subtitles, drmKid, drmKey, licenseUrl }) {
      this.url = url; this.source = source || 'Auto'; this.headers = headers;
      this.subtitles = subtitles; this.drmKid = drmKid;
      this.drmKey = drmKey; this.licenseUrl = licenseUrl;
    }
  }
  globalThis.MultimediaItem = MultimediaItem;
  globalThis.Episode = Episode;
  globalThis.StreamResult = StreamResult;
  globalThis.Actor = Actor;
  globalThis.Trailer = Trailer;
  globalThis.NextAiring = NextAiring;

  var CloudStream = {
    getLanguage: function() { return "en"; },
    getRegion:   function() { return "US"; }
  };

  globalThis.solveCaptcha = function(siteKey, url) {
    return _dartAsyncCall('solve_captcha', { siteKey, url: url || "" });
  };

  globalThis.crypto = {
    decryptAES: function(data, key, iv, options) {
      return _dartAsyncCall('crypto_decrypt_aes', {
        data, key, iv, mode: (options && options.mode) || 'cbc'
      });
    },
    pbkdf2: function(password, salt, iterations, keyLength) {
      return _dartAsyncCall('crypto_pbkdf2', {
        password, salt, iterations: iterations || 10000, keyLength: keyLength || 32
      });
    }
  };

  globalThis.JSDOM = class JSDOM {
    constructor(html) {
      this._initPromise = _dartAsyncCall('dom_parse', { html }).then((id) => {
        this.window = { document: new JSDocument(id) };
        return this;
      });
    }
    async waitForInit() { return await this._initPromise; }
  };

  globalThis.parseHtml = async function(html) {
    const dom = new JSDOM(html);
    await dom.waitForInit();
    return dom.window.document;
  };

  class JSNode {
    constructor(nodeId, data) {
      this.nodeId = nodeId; this.data = data || {};
      this.textContent = this.data.textContent || "";
      this.innerHTML   = this.data.innerHTML   || "";
      this.outerHTML   = this.data.outerHTML   || "";
      this.tagName     = this.data.tagName     || "";
    }
    get className() { return this.getAttribute('class') || ""; }
    getAttribute(name) { return this.data.attributes ? this.data.attributes[name] : null; }
    querySelector(query) {
      var res = sendMessage('dom_query', JSON.stringify({ nodeId: this.nodeId, query, multi: false }));
      if (typeof res === 'string') res = JSON.parse(res);
      return res ? new JSNode(res.nodeId, res) : null;
    }
    querySelectorAll(query) {
      var res = sendMessage('dom_query', JSON.stringify({ nodeId: this.nodeId, query, multi: true }));
      if (typeof res === 'string') res = JSON.parse(res);
      return (res || []).map(d => new JSNode(d.nodeId, d));
    }
  }
  class JSDocument extends JSNode {
    constructor(id) { super(id, { nodeId: id }); }
    get body() { return this.querySelector('body'); }
  }

  globalThis.atob = function(str) {
    if (!str) return "";
    try {
      var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
      var output = ''; str = String(str).replace(/=+$/, '');
      for (var bc=0,bs,buffer,idx=0; buffer=str.charAt(idx++); ~buffer&&(bs=bc%4?bs*64+buffer:buffer, bc++%4)?output+=String.fromCharCode(255&bs>>(-2*bc&6)):0) {
        buffer=chars.indexOf(buffer);
      }
      return output;
    } catch(e) { return ""; }
  };
  globalThis.btoa = function(str) {
    if (!str) return "";
    try {
      var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
      var output = '';
      for (var block,charCode,bc=0,idx=0,map=chars; str.charAt(idx|0)||(map='=',idx%1); output+=map.charAt(63&block>>8-idx%1*8)) {
        charCode=str.charCodeAt(idx+=3/4);
        if (charCode>0xFF) throw new Error("'btoa' failed");
        block=block<<8|charCode;
      }
      return output;
    } catch(e) { return ""; }
  };

  globalThis.URL = class URL {
    constructor(url, base) {
      this.href = url;
      if (base) {
        if (!url.startsWith('http')) {
          var b = new URL(base);
          this.href = url.startsWith('/')
            ? b.origin + url
            : b.origin + b.pathname.substring(0, b.pathname.lastIndexOf('/')+1) + url;
        }
      }
      var m = this.href.match(/^([^:/?#]+:)?(\/\/([^/?#]*))?([^?#]*)?(\?([^#]*))?(#(.*))?/);
      if (!m) throw new Error("Invalid URL");
      this.protocol=m[1]||""; this.host=m[3]||"";
      this.pathname=m[4]||"/"; this.search=m[5]||""; this.hash=m[7]||"";
      var hp=this.host.split(':');
      this.hostname=hp[0]; this.port=hp[1]||"";
      this.origin=this.protocol+"//"+this.host;
    }
    toString() { return this.href; }
  };

  globalThis.nativeDomBatch = function(nodeId, queries) {
    var res = sendMessage('dom_query_batch', JSON.stringify({ nodeId, queries }));
    if (typeof res === 'string') res = JSON.parse(res);
    return res || [];
  };
  globalThis.nativeExtract = function(html, extractionMap) {
    return _dartAsyncCall('dom_parse_and_extract', { html, extract: extractionMap });
  };
  globalThis.nativeRegex = function(text, pattern, group, caseSensitive) {
    var res = sendMessage('regex_match_all', JSON.stringify({
      text, pattern, group: group || 0, caseSensitive: caseSensitive !== false
    }));
    if (typeof res === 'string') res = JSON.parse(res);
    return res || [];
  };
  globalThis.nativeJsonExtract = function(jsonStr, paths) {
    var res = sendMessage('json_extract', JSON.stringify({ json: jsonStr, paths }));
    if (typeof res === 'string') res = JSON.parse(res);
    return res || {};
  };
  // JSON.stringify, because both engine bindings JSON-decode the second
  // argument unconditionally (quickjs_runtime2.dart and jscore_runtime.dart).
  // Passing a bare string meant jsonDecode('hello') threw FormatException into
  // the plugin on QuickJS and returned undefined on JavaScriptCore - and when
  // the input happened to parse as JSON it was worse than either: the handler
  // hashed Dart's Map.toString() output, so nativeMd5('{"a":1}') returned
  // md5('{a: 1}'). A confident wrong hash, silently.
  //
  // No `|| ''` fallback: an empty-string hash is a wrong answer that a plugin
  // will send to a server. Let it be undefined so the plugin can tell.
  globalThis.nativeMd5    = function(input) { return sendMessage('crypto_md5',    JSON.stringify(String(input))); };
  globalThis.nativeSha256 = function(input) { return sendMessage('crypto_sha256', JSON.stringify(String(input))); };
""";
