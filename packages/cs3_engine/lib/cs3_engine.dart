/// Runs CloudStream (.cs3) extensions from Flutter.
///
/// One engine per app. Android hosts it in-process, iOS in an embedded OpenJDK
/// Zero VM, and desktop in a Java sidecar process; all three speak the same
/// JSON protocol (see engine/engine-core Engine.kt).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/services.dart';

class Cs3EngineException implements Exception {
  Cs3EngineException(this.type, this.message, [this.trace]);

  final String type;
  final String message;
  final String? trace;

  @override
  String toString() => '$type: $message';
}

class Cs3Engine {
  Cs3Engine._(this._transport);

  final _Transport _transport;
  int _nextId = 0;

  /// Starts the engine. [dataDir] holds converted plugins and plugin settings. On desktop, [java]
  /// is the `java` executable to run it with (17 or newer); without it, the `CS3_JAVA`
  /// environment variable, then the Java runtime the build bundles (see tool/build_runtime.dart),
  /// then the machine's Java.
  static Future<Cs3Engine> start({required String dataDir, String? java}) async {
    final transport = Platform.isAndroid || Platform.isIOS
        ? _ChannelTransport(dataDir)
        : await _SidecarTransport.start(dataDir, java);
    return Cs3Engine._(transport);
  }

  /// False once the engine has stopped: disposed, or (desktop) the `java` process exited. The
  /// plugins it had loaded are gone with it; start another engine to go on.
  bool get isRunning => _transport.isRunning;

  /// Sends one request; returns its `result` or throws [Cs3EngineException]. Throws a
  /// [StateError] if the engine has stopped.
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> params = const {}]) async {
    final id = ++_nextId;
    final raw = await _transport.send(id, jsonEncode({'id': id, 'method': method, 'params': params}));
    final response = jsonDecode(raw) as Map<String, dynamic>;
    final error = response['error'] as Map<String, dynamic>?;
    if (error != null) {
      throw Cs3EngineException(error['type'] as String, error['message'] as String, error['trace'] as String?);
    }
    final result = response['result'];
    return result is Map<String, dynamic> ? result : {'value': result};
  }

  Future<Map<String, dynamic>> hello() => call('hello');

  /// [url] is where the plugin was downloaded from: plugins look it up (CloudStream's
  /// `PluginData.url`), and without one they count as local files.
  Future<Map<String, dynamic>> loadPlugin(String path, {String? url}) =>
      call('loadPlugin', {'path': path, 'url': ?url});

  Future<Map<String, dynamic>> unloadPlugin(String path) => call('unloadPlugin', {'path': path});

  Future<List<dynamic>> providers() async => (await call('providers'))['value'] as List<dynamic>;

  // [plugin] (the extension's path) picks between providers that share a name.

  Future<Map<String, dynamic>> mainPage(String provider, {int page = 1, String? section, String? plugin}) =>
      call('mainPage', {'provider': provider, 'page': page, 'section': ?section, 'plugin': ?plugin});

  Future<Map<String, dynamic>> search(String provider, String query, {int page = 1, String? plugin}) =>
      call('search', {'provider': provider, 'query': query, 'page': page, 'plugin': ?plugin});

  Future<Map<String, dynamic>> load(String provider, String url, {String? plugin}) =>
      call('load', {'provider': provider, 'url': url, 'plugin': ?plugin});

  /// The links [provider] found for [data]. [timeoutMs] is how long the call may run before the
  /// engine gives up and answers with the links it has: CloudStream's own limit for a provider is
  /// a few minutes, and a shorter one cut off the extensions that need longer to answer.
  Future<Map<String, dynamic>> loadLinks(String provider, String data, {int timeoutMs = 120000, String? plugin}) =>
      call('loadLinks', {'provider': provider, 'data': data, 'timeoutMs': timeoutMs, 'plugin': ?plugin});

  /// The app's repositories, each `{url, name, iconUrl?}`: what plugins see as CloudStream's list.
  Future<Map<String, dynamic>> setRepositories(List<Map<String, Object?>> repositories) =>
      call('setRepositories', {'repositories': repositories});

  /// The app's language, as a language tag (`hi`, `pt-BR`): extensions' resources loaded from then on
  /// use their strings in it, where they ship them.
  Future<Map<String, dynamic>> setLanguage(String language) => call('setLanguage', {'language': language});

  /// Bot-check clearances for every request extensions make: each `{site, cookies: {name: value},
  /// userAgent}`, `site` a registrable domain covering its subdomains. Replaces the previous set.
  /// [moves] are the hosts that moved (`{host: origin}`), whose requests the engine sends straight
  /// to where they went.
  Future<Map<String, dynamic>> setClearances(
    List<Map<String, Object?>> sites, {
    Map<String, String> moves = const {},
  }) => call('setClearances', {'sites': sites, 'moves': moves});

  /// Answers a `webRequest` event whose `op` is `solve`: the clearance for its URL, or null cookies
  /// when the check wasn't cleared. [earned]: the browser got it in this solve or moments before,
  /// rather than the app holding it from before; only an earned one meeting the check again tells
  /// the engine the site lets only the browser through.
  Future<Map<String, dynamic>> webReply(int rid, {Map<String, String>? cookies, String? userAgent, bool? earned}) =>
      call('webReply', {'rid': rid, 'cookies': ?cookies, 'userAgent': ?userAgent, 'earned': ?earned});

  /// Answers a `webRequest` event whose `op` is `fetch` or `resolve`:
  /// - for a fetch, the page's `status`, `url`, `headers` and `body`;
  /// - for a resolve, nothing, once the app is done with its page.
  ///
  /// Empty means the app couldn't.
  Future<Map<String, dynamic>> webAnswer(int rid, [Map<String, Object?> answer = const {}]) =>
      call('webReply', {...answer, 'rid': rid});

  /// A request the page of resolve [rid] made. True when the engine has what it needed, or the
  /// resolve has ended: close the page.
  Future<bool> webCaptured(int rid, String url, {String? method}) async =>
      (await call('webCaptured', {'rid': rid, 'url': url, 'method': ?method}))['value'] == true;

  /// What the script of resolve [rid] returned in its page.
  Future<void> webScript(int rid, String result) => call('webScript', {'rid': rid, 'result': result});

  /// What page [rid] did (a `webRequest` whose `op` is `page`): [type] is `started`, `finished`, `failed`, `message`,
  /// `request` or `closed`, and [fields] what it carries (`url`, `cookies`, `title`, `code`, `text`, `mainFrame`,
  /// `message`, `method`, `headers`). Two wait for the engine's answer, which this returns (Phase 7c):
  /// - `call` (`message`: an answering JavaScript call, with its `id`): `{value}`, `{error}` (it threw), or `{}`
  ///   (undefined, also after 30 s);
  /// - `dialog` (`kind`: `alert`, `confirm` or `prompt`; `message`, `defaultText`, `url`): `{accept, text?}`, or
  ///   `{show: true}` when the extension's chrome client leaves it to the app.
  Future<Map<String, dynamic>> webPage(int rid, String type, [Map<String, Object?> fields = const {}]) =>
      call('webPage', {...fields, 'rid': rid, 'type': type});

  /// Opens the extension's own settings screen ([path] must be loaded) and returns its session. Its
  /// windows arrive as `ui` events, which can come before this returns; `uiClosed` ends it. Throws when
  /// the extension has no screen, its code throws, or it shows nothing within 3 s.
  Future<int> openSettings(String path) async =>
      ((await call('openSettings', {'path': path}))['session'] as num).toInt();

  /// Applies the person's [action] to [node] of screen [session]: `click`, `longClick`, `check` (bool),
  /// `text` (string), `submit`, `select` (index), `slide` (number), `focus` (bool, forward) and `blur` on a
  /// page node (Android's lent WebView: not the person's actions), or `close` (the window holding
  /// [node]: as Back, or with `'force'` as [value], dismissed). Answers `{restarted: true}` when the
  /// extension asked to restart the app instead.
  Future<Map<String, dynamic>> uiAction(int session, int node, String action, [Object? value]) =>
      call('uiAction', {'session': session, 'node': node, 'action': action, 'value': ?value});

  /// Closes screen [session]'s windows, top first, as Back would; [force] dismisses them at once.
  Future<void> closeUi(int session, {bool force = false}) => call('closeUi', {'session': session, 'force': force});

  /// Opens the extension's kept pop-ups ([path] must be loaded) as a screen, as its Support button does, and
  /// returns its session; they're no longer kept, and closing one dismisses it. Throws when it has none.
  Future<int> openPopups(String path) async => ((await call('openPopups', {'path': path}))['session'] as num).toInt();

  /// Unloads [path] and loads it again, so its load runs anew and what its settings screen saved applies.
  /// [loadPlugin] keeps a plugin it has loaded as it is.
  Future<Map<String, dynamic>> reloadPlugin(String path, {String? url}) =>
      call('reloadPlugin', {'path': path, 'url': ?url});

  /// What the engine reports unprompted, as it happens, such as
  /// `{"event": "repositoryAdded", "url", "name", "iconUrl", "plugin"}` when a plugin adds a
  /// repository (`plugin` is its path; MegaRepo's adds a whole list when it loads).
  ///
  /// `{"event": "webRequest", "rid", "op", "url", ...}` means an extension needs the app's browser:
  /// - `solve`: a bot check to clear, with `failed` (`{name: value}`) when the request met it with a
  ///   clearance: that one has lapsed, and doesn't go back. Answer with [webReply].
  /// - `fetch`, with `method`, `headers` and `body`: a request to send from inside one of the site's
  ///   pages. Answer with [webAnswer].
  /// - `resolve`, with `headers`, `script` and `timeoutMs`: a page to load hidden. Report its
  ///   requests with [webCaptured] and its script's results with [webScript], then [webAnswer]
  ///   once the page is done with.
  /// - `page`, with `session`, `node`, `headers`, `userAgent`, `interfaces` (name to its one-way methods), `answering`
  ///   (name to its methods that answer, when it has any), `fullScreen`, and `serve` when the app serves the page's
  ///   folder (`name`, `folder`, `path` below it, and the folder's own `file` address): a page shown at a node of an
  ///   open screen (the JVM engine's web views). Report what it does with [webPage]; no answer.
  /// - `navigate`, with `headers` and `serve`, and `closePage`: the page with that `rid` loads `url` again, or goes.
  /// - `eval`, with `page` and `script`: runs the script in page `page`; answer `{result}` (JSON text) with
  ///   [webAnswer].
  ///
  /// `{"event": "ui", "session", "plugin", "windows"}`: an open screen's windows, bottom to top, after
  /// each change. `{"event": "uiClosed", "session", "plugin", "reason", "actions", "error"?}` ends it
  /// (reason: `closed`, `restart`, `replaced`, `nothing` or `error`, when the extension crashed; `error`
  /// then says how). `{"event": "restartRequested", "plugin"}`:
  /// the extension asked to restart the app; reload it instead ([reloadPlugin]).
  ///
  /// `{"event": "uiOpened", "session", "plugin", "why": "waiting"}`: a screen the engine opened by itself, for a
  /// window the extension showed while the person waits on it (a title opening, its links, or 5 s after); its
  /// `ui` events follow. Show it, and reload nothing after. `{"event": "popups", "plugin", "titles"}`: the
  /// extension's kept pop-ups, newest first, whenever they change (its Support button, [openPopups]).
  /// `{"event": "popupKept", "plugin", "title"}` and `{"event": "popupDropped", "plugin", "reason"}` say what
  /// came of one; `{"event": "popupEscaped", "plugin", "why"}` that one showed as Android draws it.
  ///
  /// `{"event": "pageFocusExit", "session", "node", "direction"}`: keyboard or D-pad focus left the page at that node
  /// (Android), towards `forward`, `backward`, `up`, `down`, `left` or `right`.
  /// What the engine reports unprompted, as it happens. A message that does not read is left out:
  /// a plugin writing to the engine's own output must not end the stream.
  Stream<Map<String, dynamic>> get events => _transport.events.map((event) {
    try {
      final decoded = jsonDecode(event);
      return decoded is Map<String, dynamic> ? decoded : const <String, dynamic>{};
    } on FormatException {
      return const <String, dynamic>{};
    }
  });

  /// Stops the engine. On desktop the `java` process exits, releasing the files it held, before
  /// this completes. Android and iOS engines live in the app process; this only detaches.
  Future<void> dispose() => _transport.close();
}

abstract class _Transport {
  bool get isRunning;
  Future<String> send(int id, String request);
  Stream<String> get events;
  Future<void> close();
}

/// Android and iOS: the native plugin hosts the engine.
class _ChannelTransport implements _Transport {
  _ChannelTransport(this._dataDir) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'event' && !_events.isClosed) _events.add(call.arguments as String);
    });
  }

  static const _channel = MethodChannel('cs3_engine');
  final String _dataDir;
  final _events = StreamController<String>.broadcast();

  @override
  bool get isRunning => !_events.isClosed;

  @override
  Future<String> send(int id, String request) async {
    if (!isRunning) throw StateError('the engine was disposed');
    return (await _channel.invokeMethod<String>('call', {'dataDir': _dataDir, 'request': request}))!;
  }

  @override
  Stream<String> get events => _events.stream;

  @override
  Future<void> close() async {
    if (_events.isClosed) return;
    _channel.setMethodCallHandler(null);
    await _events.close();
  }
}

/// Desktop: a `java` process speaking the protocol over stdin/stdout.
class _SidecarTransport implements _Transport {
  _SidecarTransport._(this._process, {required bool detached}) {
    final output = Completer<void>();
    // Plugins and native code can write any bytes; a malformed one must not end the connection.
    _process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_onLine, onDone: output.complete);
    _process.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen((text) {
      // Keep only the tail for error reports; plugins log a lot over a long session.
      if (_stderr.length > 64 * 1024) {
        final tail = _stderr.toString().substring(_stderr.length - 16 * 1024);
        _stderr
          ..clear()
          ..write(tail);
      }
      _stderr.write(text);
    });
    // Write failures on a dead process surface here; the exit handler below reports them.
    _process.stdin.done.catchError((Object _) {});
    // A detached engine has no exit code: its output closing is its end.
    _gone = detached ? output.future.then((_) => null) : _process.exitCode.then<int?>((code) => code);
    _gone.then((code) {
      final tail = _stderr.toString().split('\n').reversed.take(20).toList().reversed.join('\n');
      final error = _exitError = StateError('engine exited${code == null ? '' : ' with code $code'}:\n$tail');
      for (final pending in _pending.values) {
        pending.completeError(error);
      }
      _pending.clear();
    });
  }

  final Process _process;

  /// Completes when the engine has ended, with its exit code when it has one.
  late final Future<int?> _gone;
  final _pending = <int, Completer<String>>{};
  final _events = StreamController<String>.broadcast();
  final _stderr = StringBuffer();
  StateError? _exitError;
  bool _closing = false;

  static Future<_SidecarTransport> start(String dataDir, String? java) async {
    String? unpackError;
    var executable = java ?? Platform.environment['CS3_JAVA'];
    if (executable == null) {
      try {
        executable = await _bundledJava(dataDir);
      } catch (e) {
        unpackError = '$e';
      }
    }
    executable ??= await _machineJava();
    final classpath = '${_assetsDir()}${_sep}engine$_sep*';
    try {
      final process = await Process.start(executable, [
        '-cp',
        classpath,
        'dev.akash.cs3engine.jvm.MainKt',
        '--stdio',
        dataDir,
      ], mode: _detached ? ProcessStartMode.detachedWithStdio : ProcessStartMode.normal);
      return _SidecarTransport._(process, detached: _detached);
    } on ProcessException catch (e) {
      throw Cs3EngineException(
        'JavaNotFound',
        'CloudStream extensions need Java 17 or newer, which could not be started ($executable): ${e.message}'
            '${unpackError != null ? '. The bundled Java runtime did not unpack: $unpackError' : ''}',
      );
    }
  }

  static final _sep = Platform.pathSeparator;

  /// On Linux the engine runs detached, not as the app's child. While Dart waits on a child it
  /// started, it collects any child of the app that ends, and libVLC waits forever for a helper it
  /// runs before each connection (libproxy's `proxy`) once something else collected it: the player
  /// froze (2026-10-03). Elsewhere it stays a child: Windows needs it gone, files released, before
  /// [close] completes, which only its exit code tells.
  static final _detached = Platform.isLinux;

  /// This package's assets, inside the app bundle.
  static String _assetsDir() {
    final exe = File(Platform.resolvedExecutable).parent;
    final assets = Platform.isMacOS
        ? '${exe.parent.path}/Frameworks/App.framework/Resources/flutter_assets'
        : '${exe.path}${_sep}data${_sep}flutter_assets';
    return '$assets${_sep}packages${_sep}cs3_engine${_sep}assets';
  }

  /// The Java runtime bundled with this build for this platform, unpacked on first use (and after
  /// an update brings a new one) into a `runtime` folder beside [dataDir]. Null without one.
  static Future<String?> _bundledJava(String dataDir) async {
    final os = Platform.isMacOS ? 'macos' : (Platform.isWindows ? 'windows' : (Platform.isLinux ? 'linux' : null));
    final arch = switch (Abi.current()) {
      Abi.macosArm64 || Abi.linuxArm64 || Abi.windowsArm64 => 'arm64',
      Abi.macosX64 || Abi.linuxX64 || Abi.windowsX64 => 'x64',
      _ => null,
    };
    if (os == null || arch == null) return null;
    final archive = File('${_assetsDir()}${_sep}runtime${_sep}runtime-$os-$arch.tar.gz');
    final info = File('${_assetsDir()}${_sep}runtime${_sep}runtime-$os-$arch.json');
    if (!archive.existsSync() || !info.existsSync()) return null;

    final sha256 = (jsonDecode(await info.readAsString()) as Map<String, dynamic>)['sha256'] as String;
    final root = Directory('${Directory(dataDir).parent.path}${_sep}runtime');
    final home = Directory('${root.path}$_sep${sha256.substring(0, 16)}');
    final java = File('${home.path}${_sep}bin${_sep}java${Platform.isWindows ? '.exe' : ''}');
    if (await java.exists()) return java.path;

    // Unpacked beside and moved into place, so a half-unpacked runtime is never used.
    await root.create(recursive: true);
    final unpacking = await root.createTemp('unpacking-');
    try {
      // Windows 10 and later ship bsdtar; with it, tar keeps modes and needs no unpacking in Dart.
      final windows = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      final tar = Platform.isWindows ? '$windows${_sep}System32${_sep}tar.exe' : 'tar';
      final result = await Process.run(tar, ['-xzf', archive.path, '-C', unpacking.path]);
      if (result.exitCode != 0) throw StateError('tar exited with ${result.exitCode}: ${result.stderr}');
      await unpacking.rename(home.path);
    } finally {
      if (await unpacking.exists()) await unpacking.delete(recursive: true);
    }
    // Runtimes of earlier versions of the app go.
    await for (final entry in root.list()) {
      if (entry.path == home.path) continue;
      try {
        await entry.delete(recursive: true);
      } catch (_) {
        // In use by another instance of the app; next time.
      }
    }
    return java.path;
  }

  /// The machine's Java 17 or newer: macOS's java_home, `JAVA_HOME`, Android Studio's bundled
  /// runtime (which a developer running the app from source usually has), then `PATH`.
  static Future<String> _machineJava() async {
    if (Platform.isMacOS) {
      final home = await Process.run('/usr/libexec/java_home', ['-v', '17+']);
      if (home.exitCode == 0) return '${(home.stdout as String).trim()}/bin/java';
    }
    final javaHome = Platform.environment['JAVA_HOME'];
    if (javaHome != null && javaHome.isNotEmpty) return '$javaHome${_sep}bin${_sep}java';
    final userHome = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? '';
    final androidStudio = [
      if (Platform.isMacOS) '/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java',
      if (Platform.isWindows) ...[
        r'C:\Program Files\Android\Android Studio\jbr\bin\java.exe',
        '$userHome\\AppData\\Local\\Programs\\Android Studio\\jbr\\bin\\java.exe',
      ],
      if (Platform.isLinux) ...[
        '/opt/android-studio/jbr/bin/java',
        '$userHome/android-studio/jbr/bin/java',
        '/snap/android-studio/current/jbr/bin/java',
      ],
    ];
    for (final java in androidStudio) {
      if (await File(java).exists()) return java;
    }
    return 'java';
  }

  @override
  bool get isRunning => _exitError == null && !_closing;

  void _onLine(String line) {
    final Object? message;
    try {
      message = jsonDecode(line);
    } on FormatException {
      // Not a protocol message (native code or the JVM writing to stdout).
      _stderr.writeln(line);
      return;
    }
    if (message is! Map<String, dynamic>) return;
    // Events arrive between responses and carry no request id.
    if (message.containsKey('event')) {
      if (!_events.isClosed) _events.add(line);
    } else {
      _pending.remove(message['id'])?.complete(line);
    }
  }

  @override
  Stream<String> get events => _events.stream;

  @override
  Future<String> send(int id, String request) {
    final exited = _exitError;
    if (exited != null) return Future.error(exited);
    if (_closing) return Future.error(StateError('the engine was disposed'));
    final completer = _pending[id] = Completer<String>();
    try {
      _process.stdin.writeln(request);
    } catch (e) {
      _pending.remove(id);
      completer.completeError(StateError('engine is not accepting requests: $e'));
    }
    return completer.future;
  }

  @override
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    // Closing stdin lets the engine finish briefly and exit by itself; a stuck one is killed.
    try {
      await _process.stdin.close();
    } catch (_) {
      // Already gone.
    }
    try {
      await _gone.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      _process.kill();
      await _gone.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          _process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    }
    await _events.close();
  }
}
