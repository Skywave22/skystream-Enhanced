import 'dart:async';

import 'package:flutter/foundation.dart';

import '../cloudstream_engine.dart';
import 'ui_tree.dart';

/// What an extension screen needs from the engine, so tests can stand in for it.
abstract interface class ExtensionUiApi {
  Stream<Map<String, dynamic>> get events;

  Future<int> openSettings(String plugin);

  Future<int> openPopups(String plugin);

  Future<Map<String, dynamic>> uiAction(int session, int node, String action, [Object? value]);

  Future<void> closeUi(int session, {bool force = false});
}

/// The engine host as an [ExtensionUiApi]; [pluginUrl] loads the plugin with its address if it isn't loaded.
class HostUiApi implements ExtensionUiApi {
  HostUiApi(this._host, {this.pluginUrl});

  final CloudStreamEngineHost _host;
  final String? pluginUrl;

  @override
  Stream<Map<String, dynamic>> get events => _host.events;

  @override
  Future<int> openSettings(String plugin) => _host.openSettings(plugin, pluginUrl: pluginUrl);

  @override
  Future<int> openPopups(String plugin) => _host.openPopups(plugin, pluginUrl: pluginUrl);

  @override
  Future<Map<String, dynamic>> uiAction(int session, int node, String action, [Object? value]) =>
      _host.uiAction(session, node, action, value);

  @override
  Future<void> closeUi(int session, {bool force = false}) => _host.closeUi(session, force: force);
}

/// One extension screen open in the engine: its windows as they change, and the person's actions,
/// sent one after another. Ends when the engine says (`uiClosed`).
class ExtensionUiSession extends ChangeNotifier {
  ExtensionUiSession._(this._api, this.id, this.plugin);

  @visibleForTesting
  ExtensionUiSession.test(
    this._api, {
    this.id = 1,
    this.plugin = '/plugins/Test.cs3',
    List<UiWindow> windows = const [],
  }) {
    this.windows = windows;
  }

  /// For tests: as if the engine had sent [event].
  @visibleForTesting
  void receive(Map<String, dynamic> event) => _on(event);

  /// Opens [plugin]'s settings screen. Its first windows can arrive before the engine answers, so its
  /// events are heard from the start.
  static Future<ExtensionUiSession> open(ExtensionUiApi api, String plugin) =>
      _start(api, plugin, () => api.openSettings(plugin));

  /// Opens [plugin]'s kept pop-ups, as its Support button does; heard from the start, as [open].
  static Future<ExtensionUiSession> openPopups(ExtensionUiApi api, String plugin) =>
      _start(api, plugin, () => api.openPopups(plugin));

  /// A screen the engine opened by itself (`uiOpened`): a window the person waits on. Heard from here on; the
  /// engine reads its windows a moment after it says so.
  factory ExtensionUiSession.attach(ExtensionUiApi api, int id, String plugin) {
    final session = ExtensionUiSession._(api, id, plugin);
    session._events = api.events.listen(session._on);
    return session;
  }

  static Future<ExtensionUiSession> _start(ExtensionUiApi api, String plugin, Future<int> Function() opening) async {
    final early = <Map<String, dynamic>>[];
    final listening = api.events.listen(early.add);
    try {
      final id = await opening();
      final session = ExtensionUiSession._(api, id, plugin).._events = listening;
      for (final event in early) {
        session._on(event);
      }
      listening.onData(session._on);
      return session;
    } catch (_) {
      // Not awaited: a subscription's cancel can hand back a future of the root zone, and nothing
      // waits on it here.
      unawaited(listening.cancel());
      rethrow;
    }
  }

  final ExtensionUiApi _api;
  final int id;
  final String plugin;
  StreamSubscription<Map<String, dynamic>>? _events;

  /// Its windows, bottom to top.
  List<UiWindow> windows = const [];

  /// Why the engine closed it (`closed`, `restart`, `error`, …); null while it's open.
  String? closedReason;

  /// What the extension's crash said, when it closed the screen (`error`).
  String? closedError;

  bool get closed => closedReason != null;

  final _done = Completer<void>();

  final _pageExits = StreamController<({int node, String direction})>.broadcast();

  /// Keyboard or D-pad focus leaving a page Android lent the sheet: its node, and which way.
  Stream<({int node, String direction})> get pageExits => _pageExits.stream;

  /// Gives the page at [node] keyboard and D-pad focus (Android's lent WebView), entering at its start when
  /// [forward]. Not one of the person's actions: there's nothing to apply after it.
  void focusPage(int node, {required bool forward}) => _api.uiAction(id, node, 'focus', forward).ignore();

  /// Takes keyboard focus from the page at [node].
  void blurPage(int node) => _api.uiAction(id, node, 'blur').ignore();

  /// Completes once the engine has ended the screen (`uiClosed`), or the session is disposed.
  Future<void> get done => _done.future;

  /// Completes once the first windows have come, the screen has ended, or [timeout] has passed: what decides whether
  /// the screen opens in the sheet or full screen (Phase 7c's §2).
  Future<void> firstWindows({Duration timeout = const Duration(seconds: 2)}) {
    if (windows.isNotEmpty || closed) return Future.value();
    final ready = Completer<void>();
    void check() {
      if ((windows.isNotEmpty || closed) && !ready.isCompleted) ready.complete();
    }

    addListener(check);
    return ready.future.timeout(timeout, onTimeout: () {}).whenComplete(() => removeListener(check));
  }

  /// The extension asked to restart the app: it reloads instead.
  bool restartRequested = false;

  /// Actions the person sent, closing aside: none means nothing to apply.
  int actionsSent = 0;

  /// Why the last action failed, until one succeeds.
  Object? error;

  /// The last action sent; the next one waits for it. Null until the first.
  Future<void>? _queue;
  final Map<int, String> _typing = {};
  Timer? _typed;

  static String _path(Object? path) => '$path'.replaceAll(r'\', '/');

  void _on(Map<String, dynamic> event) {
    switch (event['event']) {
      case 'ui' when event['session'] == id:
        windows = [
          for (final window in (event['windows'] as List?) ?? const [])
            if (window is Map) UiWindow.fromJson(Map<String, dynamic>.from(window)),
        ];
        notifyListeners();
      case 'uiClosed' when event['session'] == id:
        closedReason = event['reason'] as String? ?? 'closed';
        closedError = event['error'] as String?;
        if (!_done.isCompleted) _done.complete();
        windows = const [];
        unawaited(_events?.cancel());
        notifyListeners();
      case 'pageFocusExit' when event['session'] == id:
        _pageExits.add((node: (event['node'] as num).toInt(), direction: event['direction'] as String? ?? 'forward'));
      case 'restartRequested' when _path(event['plugin']) == _path(plugin):
        restartRequested = true;
        notifyListeners();
    }
  }

  /// Sends [action] after every action before it; text being typed goes first.
  Future<void> act(int node, String action, [Object? value]) {
    _flushText();
    return _send(node, action, value);
  }

  /// The person typed [text] into [node]: sent once they pause, or before any other action.
  void type(int node, String text) {
    _typing[node] = text;
    _typed?.cancel();
    _typed = Timer(const Duration(milliseconds: 300), _flushText);
  }

  /// Closes the top window, as Back would; [force] dismisses every window at once.
  Future<void> close({bool force = false}) async {
    _flushText();
    await _queue;
    if (closed) return;
    if (force || windows.isEmpty) {
      await _api.closeUi(id, force: force);
      return;
    }
    await _send(windows.last.root.id, 'close', null);
  }

  void _flushText() {
    _typed?.cancel();
    final typed = Map.of(_typing);
    _typing.clear();
    typed.forEach((node, text) => unawaited(_send(node, 'text', text)));
  }

  Future<void> _send(int node, String action, Object? value) {
    if (action != 'close') actionsSent++;
    Future<void> send() async {
      if (closed) return;
      try {
        await _api.uiAction(id, node, action, value);
        error = null;
      } catch (e) {
        error = e;
        notifyListeners();
      }
    }

    // Chained in the caller's zone: a completed future made where the session was built would run what
    // follows it in that zone, which may not be running (a widget test's session made in setUp).
    final previous = _queue;
    final sending = previous == null ? send() : previous.then((_) => send());
    _queue = sending;
    return sending;
  }

  @override
  void dispose() {
    if (!_done.isCompleted) _done.complete();
    _typed?.cancel();
    unawaited(_events?.cancel());
    unawaited(_pageExits.close());
    super.dispose();
  }
}
