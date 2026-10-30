import 'dart:async';
import 'dart:io';

import 'package:cs3_engine/cs3_engine.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../logger/app_logger.dart';
import '../network/clearance/clearance.dart';
import '../network/clearance/site_keys.dart';
import '../providers/locale_provider.dart';
import 'cloudstream_web.dart';
import 'extension_ui/extension_pages.dart';

part 'cloudstream_engine.g.dart';

/// Where CloudStream keeps its files: under `extensions/`, so "delete all data" clears them.
class CloudStreamPaths {
  static Future<Directory> root() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/extensions/cloudstream').create(recursive: true);
  }

  /// Converted plugin code and the plugins' own settings.
  static Future<Directory> engine() async => Directory('${(await root()).path}/engine').create(recursive: true);

  static Future<Directory> plugins() async => Directory('${(await root()).path}/plugins').create(recursive: true);
}

/// Whether an extension's own screens (its settings) can be drawn here: wherever SkyStream runs. Android
/// draws them from its real windows; the desktops and iOS from the engine's stand-in views.
bool get extensionScreensSupported => _screens.contains(defaultTargetPlatform);

const _screens = {
  TargetPlatform.android,
  TargetPlatform.iOS,
  TargetPlatform.macOS,
  TargetPlatform.windows,
  TargetPlatform.linux,
};

/// What the engine host refuses with while CloudStream is switched off ([CloudStreamEngineHost.setSwitchedOff]).
/// It's no load failure: nothing about the extension is wrong, and it loads once CloudStream is on.
class CloudStreamSwitchedOff implements Exception {
  const CloudStreamSwitchedOff();

  @override
  String toString() => 'CloudStream is switched off';
}

/// The one CS3 engine the app runs, started on first use: that costs a JVM start on desktop (a
/// `java` process) and on iOS (the embedded VM), so nothing starts it before a CloudStream
/// provider is actually used. A desktop engine whose process died is started again, and loads
/// its plugins again, on the next call.
class CloudStreamEngineHost {
  CloudStreamEngineHost({ExtensionPages? pages}) : pages = pages ?? ExtensionPages.shared;

  /// The pages extension screens show on the JVM engine: closed with the engine they were for.
  final ExtensionPages pages;

  Future<Cs3Engine>? _engine;
  final Map<String, Future<Map<String, dynamic>>> _loaded = {};

  /// Plugins being uninstalled: a call already under way must not load them back.
  final Set<String> _removed = {};

  /// CloudStream switched off (its screen's switch): no extension loads. See [setSwitchedOff].
  bool _switchedOff = false;
  List<Map<String, Object?>> _repositories = const [];
  String? _language;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _loads = StreamController<({String path, Map<String, dynamic> answer})>.broadcast();
  StreamSubscription<Map<String, dynamic>>? _engineEvents;
  StreamSubscription<void>? _clearanceChanges;
  Timer? _clearancePush;

  /// Engine calls in flight, by kind: whether a person waits on an extension's request decides
  /// whether a bot check on it opens the check sheet.
  final Map<String, int> _inFlight = {};

  /// Engine calls running, with the extension making each: a bot check one of them meets is
  /// filed under it ([cloudStreamCheckSource]).
  final Map<int, ({String provider, String mainUrl})> _calls = {};
  int _nextCall = 0;

  /// Answers the engine's requests for the app's browser.
  late final _web = CloudStreamWeb(
    Clearance.instance,
    personWaiting: () => personWaitingFor(_inFlight.keys),
    source: (url) => cloudStreamCheckSource(
      url,
      _calls.values,
      Clearance.instance.siteKeys,
      moves: Clearance.instance.store.moves,
    ),
    pages: pages,
  );

  /// What the engine reports unprompted, as it happens (see [Cs3Engine.events]), whichever engine
  /// is running.
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// What each load of a plugin said, as it happens: whether it has its own settings screen, for one.
  Stream<({String path, Map<String, dynamic> answer})> get loads => _loads.stream;

  Future<Map<String, dynamic>> _announce(String path, Future<Map<String, dynamic>> load) => load.then((answer) {
    _loads.add((path: path, answer: answer));
    return answer;
  });

  Future<Cs3Engine> engine() async {
    final current = _engine;
    if (current != null) {
      final engine = await current;
      if (engine.isRunning) return engine;
      // The `java` process died, and the plugins it had loaded with it.
      if (identical(_engine, current)) {
        _engine = null;
        _loaded.clear();
      }
    }
    return _engine ??= _start();
  }

  Future<Cs3Engine> _start() async {
    try {
      final engine = await Cs3Engine.start(dataDir: (await CloudStreamPaths.engine()).path);
      // An earlier engine's pages went with it.
      unawaited(pages.closeAll());
      await _engineEvents?.cancel();
      _engineEvents = engine.events.listen((event) {
        if (event['event'] == 'webRequest') unawaited(_web.answer(EngineReplies(engine), event));
        if (event['event'] == 'siteMoved') recordSiteMoved(Clearance.instance, event);
        if (event['event'] == 'siteMoveDropped') forgetSiteMove(Clearance.instance, event);
        if (event['event'] == 'siteBrowserOnly') recordSiteBrowserOnly(Clearance.instance, event);
        _events.add(event);
      });
      await tell(engine);
      await _pushClearances(engine);
      _watchClearances();
      return engine;
    } catch (_) {
      // Let a later call try again (desktop: Java installed meanwhile).
      _engine = null;
      rethrow;
    }
  }

  /// The app's repositories, which plugins read and add to (MegaRepo's plugin adds a whole list):
  /// handed to the engine now if it is running, else when it starts.
  Future<void> setRepositories(List<Map<String, Object?>> repositories) async {
    _repositories = repositories;
    final engine = _engine;
    if (engine == null) return;
    try {
      await (await engine).setRepositories(repositories);
    } catch (_) {
      // The engine did not start or has stopped; the next one to start is handed the list.
    }
  }

  /// The app's language, which extensions' resources follow: handed to the engine now if it is
  /// running, else when it starts.
  Future<void> setLanguage(String language) async {
    _language = language;
    final engine = _engine;
    if (engine == null) return;
    try {
      await (await engine).setLanguage(language);
    } catch (_) {
      // The engine did not start or has stopped; the next one to start is told.
    }
  }

  /// What a starting engine is told before anything else: the app's repositories and language.
  @visibleForTesting
  Future<void> tell(Cs3Engine engine) async {
    await engine.setRepositories(_repositories);
    if (_language case final language?) await engine.setLanguage(language);
  }

  /// Sets whether CloudStream is switched off. While it is, nothing loads: [ensureLoaded], [reload],
  /// [reloadAfresh], [openSettings] and [run] throw [CloudStreamSwitchedOff], without starting the engine, so a
  /// screen still holding a provider can't load its extension back. What's loaded stays until [unload]; a load
  /// already under way is unloaded as it ends.
  void setSwitchedOff(bool off) => _switchedOff = off;

  /// What the plugin at [path] registered: its providers, and the sections each of them offers.
  /// The engine answers without running the plugin's load again, so this is cheap once the plugin
  /// is loaded. Null when CloudStream is switched off.
  ///
  /// The sections an extension offers change as it changes - one is renamed, another added - and
  /// the ones recorded when it was installed go stale: a section asked for by an old name answers
  /// nothing. This says what it offers now.
  ///
  /// Throws what [ensureLoaded] throws when the plugin does not load.
  Future<Map<String, dynamic>?> registration(String path, {String? pluginUrl}) async {
    if (_switchedOff) return null;
    return ensureLoaded(path, pluginUrl: pluginUrl);
  }

  /// Loads the plugin at [path] once per engine and returns what `loadPlugin` said. [pluginUrl] is
  /// where it was downloaded from, which plugins can look up (ViStream checks it).
  Future<Map<String, dynamic>> ensureLoaded(String path, {String? pluginUrl}) {
    if (_removed.contains(path)) return Future.error(StateError('$path was uninstalled'));
    if (_switchedOff) return Future.error(const CloudStreamSwitchedOff());
    final pending = _loaded[path] ??= _announce(path, _loadOn(path, (e) => e.loadPlugin(path, url: pluginUrl)));
    // A failed load is retried on the next call rather than remembered.
    return pending.catchError((Object error) {
      if (identical(_loaded[path], pending)) _loaded.remove(path);
      throw error;
    });
  }

  /// Loads [path] again, e.g. after its file was replaced by an update or a reinstall.
  Future<Map<String, dynamic>> reload(String path, {String? pluginUrl}) {
    _removed.remove(path);
    _loaded.remove(path);
    return ensureLoaded(path, pluginUrl: pluginUrl);
  }

  /// Unloads [path] and loads it again on the engine, so its load runs anew: what its settings screen
  /// saved applies. [reload] instead keeps a plugin the engine has loaded as it is.
  Future<Map<String, dynamic>> reloadAfresh(String path, {String? pluginUrl}) {
    _removed.remove(path);
    if (_switchedOff) return Future.error(const CloudStreamSwitchedOff());
    final pending = _announce(path, _loadOn(path, (e) => e.reloadPlugin(path, url: pluginUrl)));
    _loaded[path] = pending;
    return pending.catchError((Object error) {
      if (identical(_loaded[path], pending)) _loaded.remove(path);
      throw error;
    });
  }

  /// Loads [path] on the engine with [load]. A load that ends while CloudStream is switched off is unloaded again:
  /// the switch's own unload may have reached the engine before the plugin registered, and found nothing to drop.
  Future<Map<String, dynamic>> _loadOn(
    String path,
    Future<Map<String, dynamic>> Function(Cs3Engine engine) load,
  ) async {
    final engine = await this.engine();
    final answer = await load(engine);
    if (_switchedOff) {
      _loaded.remove(path)?.ignore();
      try {
        await engine.unloadPlugin(path);
      } catch (_) {
        // The engine stopped: what it had loaded went with it.
      }
    }
    return answer;
  }

  /// Opens [path]'s own settings screen, loading it first, and returns the session its `ui` events name.
  Future<int> openSettings(String path, {String? pluginUrl}) async {
    if (_switchedOff) throw const CloudStreamSwitchedOff();
    final engine = await this.engine();
    await ensureLoaded(path, pluginUrl: pluginUrl);
    return engine.openSettings(path);
  }

  /// Opens [path]'s kept pop-ups (its Support button), loading it first, and returns the session
  /// its `ui` events name.
  Future<int> openPopups(String path, {String? pluginUrl}) async {
    if (_switchedOff) throw const CloudStreamSwitchedOff();
    final engine = await this.engine();
    await ensureLoaded(path, pluginUrl: pluginUrl);
    return engine.openPopups(path);
  }

  /// See [Cs3Engine.uiAction].
  Future<Map<String, dynamic>> uiAction(int session, int node, String action, [Object? value]) async =>
      (await engine()).uiAction(session, node, action, value);

  /// See [Cs3Engine.closeUi].
  ///
  /// A screen the engine has already ended, or an engine that stopped, is
  /// nothing to close: the app says so and goes on. The engine that is
  /// running is asked directly, so a screen whose engine is gone does not
  /// start a fresh one to be told so.
  Future<void> closeUi(int session, {bool force = false}) async {
    try {
      final current = _engine;
      if (current != null) {
        final running = await current;
        // The engine stopped: the screen went with it.
        if (!running.isRunning) return;
        await running.closeUi(session, force: force);
        return;
      }
      // No engine of our own: a host that keeps one elsewhere (a platform
      // that hosts the engine in the app, a test) is asked directly.
      await (await engine()).closeUi(session, force: force);
    } catch (error) {
      talker.warning('[CloudStream] closing an extension screen failed: $error');
    }
  }

  /// Runs [call] on the engine with the plugin at [path] loaded. If the engine stopped (desktop:
  /// the `java` process died) or forgot the plugin, it is started or loaded again, once.
  ///
  /// [kind] is the provider call (`search`, `mainPage`, `load`, `loadLinks`): it decides how a bot
  /// check met meanwhile is handled. [pluginUrl]: see [ensureLoaded].
  Future<T> run<T>(
    String path,
    Future<T> Function(Cs3Engine engine) call, {
    String kind = 'call',
    String? provider,
    String mainUrl = '',
    String? pluginUrl,
  }) async {
    if (_switchedOff) throw const CloudStreamSwitchedOff();
    _inFlight[kind] = (_inFlight[kind] ?? 0) + 1;
    final id = _nextCall++;
    if (provider != null) _calls[id] = (provider: provider, mainUrl: mainUrl);
    try {
      return await _run(path, call, pluginUrl);
    } finally {
      _calls.remove(id);
      final left = (_inFlight[kind] ?? 1) - 1;
      if (left > 0) {
        _inFlight[kind] = left;
      } else {
        _inFlight.remove(kind);
      }
    }
  }

  Future<T> _run<T>(String path, Future<T> Function(Cs3Engine engine) call, String? pluginUrl) async {
    Future<T> attempt() async {
      final engine = await this.engine();
      await ensureLoaded(path, pluginUrl: pluginUrl);
      return call(engine);
    }

    try {
      return await attempt();
    } on StateError {
      if (_removed.contains(path)) rethrow;
      return attempt();
    } on Cs3EngineException catch (e) {
      if (!e.message.contains('no loaded provider') || _removed.contains(path)) rethrow;
      _loaded.remove(path)?.ignore();
      return attempt();
    }
  }

  /// Unloads the plugin at [path]. Unless it is only being replaced ([uninstalling] false: an
  /// update, or a utility plugin run again), calls already under way cannot load it back.
  Future<void> unload(String path, {bool uninstalling = true}) async {
    if (uninstalling) _removed.add(path);
    if (_loaded.remove(path) == null || _engine == null) return;
    await (await engine()).unloadPlugin(path);
  }

  /// Hands the engine every site's clearance, so extensions' requests carry them.
  Future<void> _pushClearances(Cs3Engine engine) async {
    final clearance = Clearance.instance;
    if (!clearance.isReady) return;
    try {
      await engine.setClearances(
        clearance.liveClearances(),
        moves: {for (final e in clearance.store.moves.entries) e.key: e.value.toString()},
      );
    } catch (_) {
      // The engine stopped; the next one is handed them when it starts.
    }
  }

  void _watchClearances() {
    final clearance = Clearance.instance;
    if (_clearanceChanges != null || !clearance.isReady) return;
    _clearanceChanges = clearance.store.changes.listen((_) {
      _clearancePush?.cancel();
      _clearancePush = Timer(const Duration(milliseconds: 300), () async {
        final engine = _engine;
        if (engine != null) await _pushClearances(await engine);
      });
    });
  }

  /// Stops the engine: on desktop the `java` process exits, releasing the plugin files it held
  /// (Windows will not delete them otherwise). The next call starts a new one.
  Future<void> dispose() async {
    await pages.closeAll();
    _clearancePush?.cancel();
    await _clearanceChanges?.cancel();
    _clearanceChanges = null;
    final engine = _engine;
    _engine = null;
    _loaded.clear();
    if (engine == null) return;
    try {
      await (await engine).dispose();
    } catch (_) {
      // It never started.
    }
  }
}

@Riverpod(keepAlive: true)
CloudStreamEngineHost cloudStreamEngineHost(Ref ref) {
  final host = CloudStreamEngineHost();
  // Extensions' resources follow the app's language: their strings in it, where they ship them.
  ref.listen(localeProvider, (_, locale) => unawaited(host.setLanguage(locale.toLanguageTag())), fireImmediately: true);
  ref.onDispose(() => unawaited(host.dispose()));
  return host;
}

/// Which CloudStream extension a bot check on [url] belongs to: the running one whose own site it
/// is, else the only one running, else none in particular (`cs3`). The engine's requests don't say
/// which extension sent them. [moves] finds an extension whose site moved.
@visibleForTesting
String cloudStreamCheckSource(
  Uri url,
  Iterable<({String provider, String mainUrl})> running,
  SiteKeys keys, {
  Map<String, Uri> moves = const {},
}) {
  final site = keys.siteOf(url.host);
  final calls = running.toList();
  for (final call in calls) {
    final home = Uri.tryParse(call.mainUrl)?.host ?? '';
    if (home.isEmpty) continue;
    final homeSite = keys.siteOf(home);
    // Moves are kept by host: any host of the extension's site that moved.
    final moved = moves.entries.any(
      (move) => keys.siteOf(move.key) == homeSite && keys.siteOf(move.value.host) == site,
    );
    if (homeSite == site || moved) return call.provider;
  }
  final providers = {for (final call in calls) call.provider};
  return providers.length == 1 ? providers.single : 'cs3';
}

/// Saves a move the engine saw (its `siteMoved` event): a request that reached another host through
/// permanent redirects that kept its path and query. The app's site list decides whether the two
/// hosts are two sites.
@visibleForTesting
void recordSiteMoved(Clearance clearance, Map<String, dynamic> event) {
  if (!clearance.isReady) return;
  final from = Uri.tryParse(event['from'] as String? ?? '');
  final to = Uri.tryParse(event['to'] as String? ?? '');
  if (from == null || to == null || !to.hasScheme) return;
  final keys = clearance.siteKeys;
  // Back on the address the extension asked for: it moved back.
  if (keys.siteOf(from.host) == keys.siteOf(to.host)) return clearance.store.forgetMove(from.host);
  clearance.store.recordMove(from.host, Uri(scheme: to.scheme, host: to.host, port: to.hasPort ? to.port : null));
}

/// Keeps a site the engine found lets only the browser through (its `siteBrowserOnly` event): a fresh clearance
/// didn't lift its refusal, and its page got past it. Its requests then go to its pages first, in this engine run and
/// the next ones.
@visibleForTesting
void recordSiteBrowserOnly(Clearance clearance, Map<String, dynamic> event) {
  if (!clearance.isReady) return;
  final url = Uri.tryParse(event['url'] as String? ?? '');
  if (url == null || url.host.isEmpty) return;
  clearance.store.markBrowserOnly(clearance.siteKeys.siteOf(url.host));
}

/// Forgets a move whose new domain stopped answering the engine (its `siteMoveDropped` event).
@visibleForTesting
void forgetSiteMove(Clearance clearance, Map<String, dynamic> event) {
  if (!clearance.isReady) return;
  final from = Uri.tryParse(event['from'] as String? ?? '');
  if (from != null && from.host.isNotEmpty) clearance.store.forgetMove(from.host);
}

/// Whether a person waits on a bot check an extension met, from the engine calls in flight
/// ([CloudStreamEngineHost.run]'s kinds): a title opening or its links do. Every call may start a
/// solve (the owner, 2026-10-03).
@visibleForTesting
bool personWaitingFor(Iterable<String> inFlight) {
  final kinds = inFlight.toSet();
  return kinds.contains('load') || kinds.contains('loadLinks');
}
