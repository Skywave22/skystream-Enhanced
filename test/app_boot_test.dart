/// What a launch owes a user who already has plugins installed.
///
/// The app's whole notion of "a stream provider" comes from one list:
/// `ExtensionsController.installedPlugins`. `ExtensionsSyncBridge` listens for
/// that list to change and hands it to [ExtensionManager], which is what
/// `getAllProviders()`, search, the details screen's source list, the download
/// launcher and the home screen all read. Nothing else ever writes it.
///
/// So the one thing a cold start must always do is read the installed
/// inventory off local disk. It used to, unconditionally. When the *update*
/// check moved off the launch critical path and behind its gates (nothing
/// checked for six hours, not on a metered connection) the inventory load went
/// with it, because both lived inside `ensureInitialized()` - and every gate
/// returns before that call. The result on a second launch inside six hours,
/// or on any launch over cellular: no providers, and a home screen that spins
/// forever because `ActiveProvider` is still waiting for a sync that can never
/// arrive.
///
/// These tests boot the real widget tree `main()` builds - `ProviderScope` ->
/// `ExtensionsSyncBridge` -> `MyApp` - with both gates deliberately shut, and
/// assert the plugins arrive anyway.
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/extensions/base_provider.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/core/extensions/models/extension_plugin.dart';
import 'package:skystream/core/extensions/models/extension_repository.dart';
import 'package:skystream/core/extensions/providers.dart';
import 'package:skystream/core/extensions/services/plugin_storage_service.dart';
import 'package:skystream/core/extensions/services/repository_service.dart';
import 'package:skystream/core/providers/update_provider.dart';
import 'package:skystream/core/router/app_router.dart';
import 'package:skystream/core/services/download_service.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/features/extensions/providers/extensions_controller.dart';
import 'package:skystream/features/extensions/widgets/extensions_sync_bridge.dart';
import 'package:skystream/main.dart';

const String _repoUrl = 'https://example.test/repo.json';
const String _packageName = 'com.example.superstream';

final ExtensionPlugin _installedPlugin = ExtensionPlugin(
  packageName: _packageName,
  name: 'SuperStream',
  repositoryId: 'com.example',
  sourceUrl: 'https://example.test/superstream-v1.sky',
  version: 1,
);

class _FakeProvider extends SkyStreamProvider {
  _FakeProvider(this.packageName);

  @override
  final String packageName;
  @override
  String get name => 'SuperStream';
  @override
  String get mainUrl => 'https://example.test';
  @override
  String get version => '1';
  @override
  List<String> get languages => const <String>['en'];
  @override
  Set<ProviderType> get supportedTypes => const <ProviderType>{
    ProviderType.movie,
  };

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) => throw UnimplementedError();
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() =>
      throw UnimplementedError();
  @override
  Future<MultimediaItem> getDetails(String url) => throw UnimplementedError();
  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      throw UnimplementedError();
}

/// The plugins the user has on disk.
class _FakePluginStorageService extends PluginStorageService {
  int listCalls = 0;

  @override
  Future<List<ExtensionPlugin>> listInstalledPlugins() async {
    listCalls++;
    return <ExtensionPlugin>[_installedPlugin];
  }
}

/// Records every byte the launch would have spent on the network.
class _FakeRepositoryService extends RepositoryService {
  _FakeRepositoryService() : super(Dio());

  final List<String> fetchCalls = <String>[];

  @override
  Future<ExtensionRepository?> fetchRepository(String url) async {
    fetchCalls.add(url);
    return ExtensionRepository(
      name: 'Example',
      url: url,
      pluginLists: const <String>[],
      explicitId: 'com.example',
    );
  }

  @override
  Future<List<ExtensionPlugin>> getRepoPlugins(
    ExtensionRepository repo,
  ) async => const <ExtensionPlugin>[];
}

/// Stands in for the QuickJS-backed manager: the real one spawns an isolate.
/// Keeps the contract that matters here - a synced plugin becomes a provider,
/// and the sync-complete flag is raised when it is done.
class _FakeExtensionManager extends ExtensionManager {
  final List<List<String>> syncedPackages = <List<String>>[];

  @override
  List<SkyStreamProvider> build() => const <SkyStreamProvider>[];

  @override
  Future<void> syncFromPlugins(List<ExtensionPlugin> installed) async {
    syncedPackages.add(
      installed.map((ExtensionPlugin p) => p.packageName).toList(),
    );
    state = installed
        .map((ExtensionPlugin p) => _FakeProvider(p.packageName))
        .toList();
    ref.read(pluginSyncCompleteProvider.notifier).set(true);
  }
}

/// `init()` reaches for the background_downloader platform channel.
class _NoopDownloadService extends DownloadService {
  _NoopDownloadService(super.ref);

  @override
  Future<void> init() async {}
}

/// `checkForUpdates()` reaches GitHub over the real network after 5 s.
class _NoopUpdateController extends UpdateController {
  @override
  UpdateState build() => UpdateInitial();

  @override
  Future<void> checkForUpdates() async {}
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late StorageService storage;
  late _FakePluginStorageService pluginStorage;
  late _FakeRepositoryService repos;
  late _FakeExtensionManager manager;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('app_boot');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => dir.path,
    );
    // `CustomTitleBar` asks the window for its state on the desktop legs.
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (MethodCall call) async => call.method.startsWith('is') ? false : null,
    );
    storage = StorageService();
    await storage.init();
    pluginStorage = _FakePluginStorageService();
    repos = _FakeRepositoryService();
    manager = _FakeExtensionManager();
  });

  tearDown(() async {
    await Hive.close();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    );
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// Runs [body] with the widget layer agreeing with `dart:io` about which
  /// platform this is.
  ///
  /// `MyApp.build` branches on `Platform`, and the desktop branches it takes -
  /// a macOS `PlatformMenuBar`, a Windows/Linux `CustomTitleBar` - throw if
  /// the widget layer disagrees, which by default in a widget test it does
  /// (Android). It has to be scoped to the body: flutter_test insists every
  /// foundation debug variable is back to its default by the time the body
  /// returns, so `setUp`/`tearDown` is too late.
  Future<void> onHostPlatform(Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = Platform.isMacOS
        ? TargetPlatform.macOS
        : Platform.isWindows
        ? TargetPlatform.windows
        : Platform.isLinux
        ? TargetPlatform.linux
        : null;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  /// Boots the tree `main()` boots, with both update-check gates shut: the
  /// clock says a check just happened, and the connection is metered.
  Future<ProviderContainer> boot(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ExtensionsController.repoUrlsKey: <String>[_repoUrl],
      ExtensionsController.lastAutoCheckKey:
          DateTime.now().millisecondsSinceEpoch,
    });

    final ProviderContainer container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        pluginStorageServiceProvider.overrideWithValue(pluginStorage),
        repositoryServiceProvider.overrideWithValue(repos),
        extensionManagerProvider.overrideWith(() => manager),
        meteredConnectionProvider.overrideWithValue(() async => true),
        downloadServiceProvider.overrideWith(_NoopDownloadService.new),
        updateControllerProvider.overrideWith(_NoopUpdateController.new),
        appRouterProvider.overrideWithValue(
          GoRouter(
            routes: <RouteBase>[
              GoRoute(
                path: '/',
                builder: (BuildContext c, GoRouterState s) =>
                    const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    // The home screen is what reads this on a real launch; reading it here is
    // what makes `ActiveProvider` resolve its stored id, exactly as
    // `home_screen.dart` does.
    container.read(activeProviderProvider);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ExtensionsSyncBridge(child: MyApp()),
      ),
    );
    // First frame, then the post-frame callback's disk work, then the sync
    // bridge's 500 ms coalescing window.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    return container;
  }

  /// Lets the two delayed launch tasks (5 s app update, 15 s extension update
  /// check) fire so no timer outlives the test.
  Future<void> settleLaunchTimers(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 20));
    await tester.pump();
  }

  testWidgets(
    'a launch loads the installed plugins even with every update gate shut',
    (WidgetTester tester) async => onHostPlatform(() async {
      // Real Hive I/O cannot complete inside `testWidgets`' fake-async zone.
      await tester.runAsync(() => storage.setActiveProviderId(_packageName));

      final ProviderContainer container = await boot(tester);

      expect(
        pluginStorage.listCalls,
        greaterThan(0),
        reason: 'the launch never read the installed plugins off disk',
      );
      expect(
        container
            .read(extensionsControllerProvider)
            .installedPlugins
            .map((ExtensionPlugin p) => p.packageName),
        <String>[_packageName],
      );
      expect(manager.syncedPackages, <List<String>>[
        <String>[_packageName],
      ], reason: 'the installed plugins never reached ExtensionManager');
      expect(
        container
            .read(extensionManagerProvider)
            .map((SkyStreamProvider p) => p.packageName),
        <String>[_packageName],
        reason: 'getAllProviders() is empty: nothing can be searched or played',
      );

      // The user-visible consequence: home stops spinning and the provider
      // they picked last time is active again.
      expect(
        container.read(providerResolutionLoadingProvider),
        isFalse,
        reason: 'the home screen would still be showing its loading indicator',
      );
      expect(container.read(activeProviderProvider)?.packageName, _packageName);

      // And none of it cost the data plan: the gates still hold for the
      // network side of the launch.
      expect(
        repos.fetchCalls,
        isEmpty,
        reason: 'a repository manifest was fetched over a metered connection',
      );

      await settleLaunchTimers(tester);
      expect(
        repos.fetchCalls,
        isEmpty,
        reason: 'the delayed update check ignored the metered gate',
      );
    }),
  );

  testWidgets(
    'a launch with no active provider still loads the plugins',
    (WidgetTester tester) async => onHostPlatform(() async {
      final ProviderContainer container = await boot(tester);

      expect(
        container
            .read(extensionManagerProvider)
            .map((SkyStreamProvider p) => p.packageName),
        <String>[_packageName],
        reason:
            'the provider picker would offer nothing and Home would claim no '
            'plugins are installed',
      );
      expect(container.read(providerResolutionLoadingProvider), isFalse);

      await settleLaunchTimers(tester);
    }),
  );
}
