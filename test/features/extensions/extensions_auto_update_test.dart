/// What the app is allowed to do to the user's plugins, and their data plan,
/// on a launch they did not ask anything of.
///
/// The startup path used to be: first post-frame callback -> `ensureInitialized`
/// -> one HTTP round trip per repository *in series* -> `checkForUpdates`, which
/// downloaded and installed every outdated plugin on the spot and then told the
/// user it had. Three separate problems in one line of `main.dart`:
///
///  * it raced the home screen for bandwidth and main-isolate time, on every
///    cold start, with no interval and no gate;
///  * on a phone on cellular it spent the user's money unannounced;
///  * it put third-party executable JavaScript on the device without anyone
///    agreeing to it.
///
/// The contract now: the check *finds* updates and records them in
/// `availableUpdates` - which the Extensions screen already renders a per-plugin
/// update button off - and installs nothing. And it declines to run at all
/// when there is nothing to find, when it ran recently, or when the connection
/// is metered.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/core/extensions/models/extension_plugin.dart';
import 'package:skystream/core/extensions/models/extension_repository.dart';
import 'package:skystream/core/extensions/providers.dart';
import 'package:skystream/core/extensions/services/plugin_storage_service.dart';
import 'package:skystream/core/extensions/services/repository_service.dart';
import 'package:skystream/core/extensions/base_provider.dart';
import 'package:skystream/core/storage/settings_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/features/extensions/providers/extensions_controller.dart';

const String _repoUrl = 'https://example.test/repo.json';
const String _packageName = 'com.example.superstream';

ExtensionPlugin _plugin(int version) => ExtensionPlugin(
  packageName: _packageName,
  name: 'SuperStream',
  repositoryId: 'com.example',
  sourceUrl: 'https://example.test/superstream-v$version.sky',
  version: version,
);

/// Records every network verb the controller reaches for, and can be made slow
/// so overlapping calls are observable.
class _FakeRepositoryService extends RepositoryService {
  _FakeRepositoryService({
    this.online = const <ExtensionPlugin>[],
    this.fetchDelay = Duration.zero,
  }) : super(Dio());

  final List<ExtensionPlugin> online;
  final Duration fetchDelay;

  final List<String> fetchCalls = <String>[];
  final List<String> downloadCalls = <String>[];

  /// How many `fetchRepository` calls were ever in flight at the same moment.
  int peakConcurrency = 0;
  int _inFlight = 0;

  @override
  Future<ExtensionRepository?> fetchRepository(String url) async {
    fetchCalls.add(url);
    _inFlight++;
    peakConcurrency = _inFlight > peakConcurrency ? _inFlight : peakConcurrency;
    try {
      if (fetchDelay > Duration.zero) await Future<void>.delayed(fetchDelay);
      return ExtensionRepository(
        name: 'Example',
        url: url,
        pluginLists: const <String>[],
        explicitId: 'com.example',
      );
    } finally {
      _inFlight--;
    }
  }

  @override
  Future<List<ExtensionPlugin>> getRepoPlugins(
    ExtensionRepository repo,
  ) async => online;

  /// A real file, so the ablation's install path runs to completion instead of
  /// bailing out early and looking like the fix.
  @override
  Future<File?> downloadPlugin(String url) async {
    downloadCalls.add(url);
    final file = File(
      '${Directory.systemTemp.createTempSync('sky_plugin').path}/plugin.sky',
    );
    await file.writeAsString('not really a zip');
    return file;
  }
}

class _FakePluginStorageService extends PluginStorageService {
  _FakePluginStorageService(this._installed);

  List<ExtensionPlugin> _installed;
  final List<String> installCalls = <String>[];

  @override
  Future<List<ExtensionPlugin>> listInstalledPlugins() async =>
      List<ExtensionPlugin>.of(_installed);

  @override
  Future<ExtensionPlugin?> installPlugin(
    String filePath,
    String? explicitRepoId,
  ) async {
    installCalls.add(filePath);
    // What a real install does: the newer plugin replaces the older one on
    // disk, so the next listing reports it.
    _installed = <ExtensionPlugin>[_plugin(2)];
    return _plugin(2);
  }
}

class _FakeSettingsRepository extends SettingsRepository {
  _FakeSettingsRepository() : super(StorageService());

  @override
  bool getDevLoadAssets() => false;
}

/// The JS engine is not under test here, and constructing the real one spawns
/// an isolate. The ablation runs through `reloadPlugin`, so it has to exist.
class _NoopExtensionManager extends ExtensionManager {
  @override
  List<SkyStreamProvider> build() => const <SkyStreamProvider>[];

  @override
  Future<void> reloadPlugin(ExtensionPlugin plugin) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeRepositoryService repos;
  late _FakePluginStorageService plugins;

  ProviderContainer boot({
    List<ExtensionPlugin> installed = const <ExtensionPlugin>[],
    List<ExtensionPlugin> online = const <ExtensionPlugin>[],
    Map<String, Object> prefs = const <String, Object>{},
    bool metered = false,
    Duration fetchDelay = Duration.zero,
  }) {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ExtensionsController.repoUrlsKey: <String>[_repoUrl],
      ...prefs,
    });
    repos = _FakeRepositoryService(online: online, fetchDelay: fetchDelay);
    plugins = _FakePluginStorageService(installed);

    final container = ProviderContainer(
      overrides: [
        repositoryServiceProvider.overrideWithValue(repos),
        pluginStorageServiceProvider.overrideWithValue(plugins),
        settingsRepositoryProvider.overrideWithValue(_FakeSettingsRepository()),
        extensionManagerProvider.overrideWith(_NoopExtensionManager.new),
        meteredConnectionProvider.overrideWithValue(() async => metered),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('an available update is recorded, not installed', () async {
    final container = boot(
      installed: <ExtensionPlugin>[_plugin(1)],
      online: <ExtensionPlugin>[_plugin(2)],
    );

    final pending = await container
        .read(extensionsControllerProvider.notifier)
        .autoCheckForUpdates();

    // The whole point: the bundle was never fetched and never written.
    expect(
      repos.downloadCalls,
      isEmpty,
      reason: 'a JavaScript bundle was downloaded without being asked for',
    );
    expect(plugins.installCalls, isEmpty);

    final state = container.read(extensionsControllerProvider);
    expect(
      state.installedPlugins.single.version,
      1,
      reason: 'the installed plugin was replaced behind the user',
    );
    // ...but the offer is on the table, which is what the Extensions screen's
    // per-plugin update button renders off.
    expect(state.availableUpdates[_packageName]?.version, 2);
    expect(pending, <String>['SuperStream']);
  });

  test('nothing newer means nothing offered', () async {
    final container = boot(
      installed: <ExtensionPlugin>[_plugin(2)],
      online: <ExtensionPlugin>[_plugin(2)],
    );

    final pending = await container
        .read(extensionsControllerProvider.notifier)
        .autoCheckForUpdates();

    expect(pending, isEmpty);
    expect(
      container.read(extensionsControllerProvider).availableUpdates,
      isEmpty,
    );
    expect(repos.downloadCalls, isEmpty);
  });

  test('a metered connection is left alone', () async {
    final container = boot(
      installed: <ExtensionPlugin>[_plugin(1)],
      online: <ExtensionPlugin>[_plugin(2)],
      metered: true,
    );

    final pending = await container
        .read(extensionsControllerProvider.notifier)
        .autoCheckForUpdates();

    expect(pending, isEmpty);
    expect(
      repos.fetchCalls,
      isEmpty,
      reason: 'a repository manifest was fetched over cellular',
    );
    // The timestamp is not moved either, so the next Wi-Fi launch still checks.
    final store = await SharedPreferences.getInstance();
    expect(store.getInt(ExtensionsController.lastAutoCheckKey), isNull);
  });

  test('a check inside the interval does not run again', () async {
    final recent = DateTime.now().subtract(const Duration(hours: 1));
    final container = boot(
      installed: <ExtensionPlugin>[_plugin(1)],
      online: <ExtensionPlugin>[_plugin(2)],
      prefs: <String, Object>{
        ExtensionsController.lastAutoCheckKey: recent.millisecondsSinceEpoch,
      },
    );

    expect(
      await container
          .read(extensionsControllerProvider.notifier)
          .autoCheckForUpdates(),
      isEmpty,
    );
    expect(repos.fetchCalls, isEmpty);
  });

  test(
    'a check older than the interval runs, and re-stamps the clock',
    () async {
      final stale = DateTime.now().subtract(
        ExtensionsController.autoCheckInterval + const Duration(minutes: 1),
      );
      final container = boot(
        installed: <ExtensionPlugin>[_plugin(1)],
        online: <ExtensionPlugin>[_plugin(2)],
        prefs: <String, Object>{
          ExtensionsController.lastAutoCheckKey: stale.millisecondsSinceEpoch,
        },
      );

      expect(
        await container
            .read(extensionsControllerProvider.notifier)
            .autoCheckForUpdates(),
        <String>['SuperStream'],
      );
      expect(repos.fetchCalls, <String>[_repoUrl]);

      final store = await SharedPreferences.getInstance();
      expect(
        store.getInt(ExtensionsController.lastAutoCheckKey),
        greaterThan(stale.millisecondsSinceEpoch),
      );
    },
  );

  test('no repositories means no work at all', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = boot(prefs: <String, Object>{});
    // boot() seeds one URL; clear it to model a fresh install.
    await (await SharedPreferences.getInstance()).remove(
      ExtensionsController.repoUrlsKey,
    );

    expect(
      await container
          .read(extensionsControllerProvider.notifier)
          .autoCheckForUpdates(),
      isEmpty,
    );
    expect(repos.fetchCalls, isEmpty);
  });

  test(
    'repositories are fetched concurrently, not one after another',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ExtensionsController.repoUrlsKey: <String>[
          'https://a.test/r.json',
          'https://b.test/r.json',
          'https://c.test/r.json',
        ],
      });
      repos = _FakeRepositoryService(
        fetchDelay: const Duration(milliseconds: 50),
      );
      plugins = _FakePluginStorageService(const <ExtensionPlugin>[]);
      final container = ProviderContainer(
        overrides: [
          repositoryServiceProvider.overrideWithValue(repos),
          pluginStorageServiceProvider.overrideWithValue(plugins),
          settingsRepositoryProvider.overrideWithValue(
            _FakeSettingsRepository(),
          ),
          extensionManagerProvider.overrideWith(_NoopExtensionManager.new),
          meteredConnectionProvider.overrideWithValue(() async => false),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(extensionsControllerProvider.notifier)
          .ensureInitialized();

      expect(
        repos.peakConcurrency,
        3,
        reason: 'three repositories still cost three round trips end to end',
      );
      // Order is the persisted order, not the order the network answered in.
      expect(
        container
            .read(extensionsControllerProvider)
            .repositories
            .map((ExtensionRepository r) => r.url),
        <String>[
          'https://a.test/r.json',
          'https://b.test/r.json',
          'https://c.test/r.json',
        ],
      );
    },
  );
}
