import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/extensions/models/extension_plugin.dart';
import '../../../../core/extensions/models/extension_repository.dart';
import '../../../../core/extensions/extension_manager.dart';
import '../../../../core/extensions/providers.dart';
import '../../../../core/extensions/services/repository_service.dart';
import '../../../core/storage/settings_repository.dart';

part 'extensions_controller.g.dart';

/// Whether the device is on a connection the user pays for by the byte.
///
/// A `Provider` holding a function rather than a `FutureProvider` so a test can
/// pin the answer with no platform channel and no cached async value, and so
/// each call asks afresh - a laptop moves between Wi-Fi and a phone hotspot
/// inside one app session.
final meteredConnectionProvider = Provider<Future<bool> Function()>(
  (ref) => isMeteredConnection,
);

/// Deliberately answers "no" unless the platform positively says cellular.
///
/// Wi-Fi or Ethernet anywhere in the list settles it: an Android phone
/// tethering over Wi-Fi still reports `wifi`, and a wired desktop must never be
/// mistaken for a phone on a data plan. `vpn` and `other` - all iOS and macOS
/// report while a VPN is up - say nothing about the transport underneath, and a
/// plugin failure must not become a permanent block on ever checking again.
Future<bool> isMeteredConnection() async {
  try {
    final results = await Connectivity().checkConnectivity();
    if (results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet)) {
      return false;
    }
    return results.contains(ConnectivityResult.mobile) ||
        results.contains(ConnectivityResult.satellite);
  } catch (_) {
    return false;
  }
}

// State for the Extensions Screen (Sealed Class Hierarchy)
sealed class ExtensionsState {
  final List<ExtensionPlugin> installedPlugins;
  final List<ExtensionRepository> repositories;
  final Map<String, List<ExtensionPlugin>> availablePlugins; // Key: Repo URL
  final Map<String, ExtensionPlugin> availableUpdates; // Key: PackageID
  final Set<String> installingPlugins; // Key: PackageName

  const ExtensionsState({
    this.installedPlugins = const [],
    this.repositories = const [],
    this.availablePlugins = const {},
    this.availableUpdates = const {},
    this.installingPlugins = const {},
  });
}

final class ExtensionsLoading extends ExtensionsState {
  const ExtensionsLoading({
    super.installedPlugins,
    super.repositories,
    super.availablePlugins,
    super.availableUpdates,
    super.installingPlugins,
  });
}

final class ExtensionsSuccess extends ExtensionsState {
  const ExtensionsSuccess({
    required super.installedPlugins,
    required super.repositories,
    required super.availablePlugins,
    required super.availableUpdates,
    super.installingPlugins,
  });
}

final class ExtensionsError extends ExtensionsState {
  final String message;

  const ExtensionsError(
    this.message, {
    super.installedPlugins,
    super.repositories,
    super.availablePlugins,
    super.availableUpdates,
    super.installingPlugins,
  });
}

@Riverpod(keepAlive: true)
class ExtensionsController extends _$ExtensionsController {
  /// SharedPreferences key holding the repository URLs the user has added.
  static const String repoUrlsKey = 'extension_repo_urls';

  /// SharedPreferences key holding when [autoCheckForUpdates] last completed,
  /// as milliseconds since epoch.
  static const String lastAutoCheckKey = 'extensions_last_update_check';

  /// How long after a completed background check the next launch may run one.
  ///
  /// Matches `NuvioRepository.autoUpdateInterval`, and for the same reason: a
  /// cold start is not evidence that a repository moved, and someone who opens
  /// the app six times a day does not want six rounds of manifest fetches.
  static const Duration autoCheckInterval = Duration(hours: 6);

  bool _initialized = false;

  @override
  ExtensionsState build() {
    return const ExtensionsLoading();
  }

  /// Call once (e.g. from Extensions screen or app startup) to load plugins and repos.
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    await _init();
  }

  Future<void> _init() async {
    state = ExtensionsLoading(
      installedPlugins: state.installedPlugins,
      repositories: state.repositories,
      availablePlugins: state.availablePlugins,
      availableUpdates: state.availableUpdates,
      installingPlugins: state.installingPlugins,
    );
    try {
      final storageService = ref.read(pluginStorageServiceProvider);
      final repositoryService = ref.read(repositoryServiceProvider);

      // 1. Load Installed Plugins
      final plugins = await storageService.listInstalledPlugins();
      if (ref.read(settingsRepositoryProvider).getDevLoadAssets()) {
        final assetPlugins = await _loadAssetPlugins();
        plugins.addAll(assetPlugins);
      }

      // 2. Load Repositories.
      //
      // One repository per future rather than a serial loop: the manifest and
      // its plugin lists are independent per repo, and a user with five
      // repositories used to wait for five round trips end to end - on the
      // Extensions screen that is five spinner-seconds they watch.
      final prefs = await SharedPreferences.getInstance();
      final urls = prefs.getStringList(repoUrlsKey) ?? [];

      final fetched = await Future.wait(
        urls.map((url) => _loadRepo(url, repositoryService)),
      );

      final repos = <ExtensionRepository>[];
      final available = <String, List<ExtensionPlugin>>{};
      // Rebuilt in the persisted order, which Future.wait preserves, so the
      // list the user sees does not reshuffle itself by network latency.
      for (final entry in fetched) {
        if (entry == null) continue;
        repos.add(entry.repo);
        available[entry.repo.url] = entry.plugins;
      }

      // 3. Set Final State Once
      state = ExtensionsSuccess(
        installedPlugins: plugins,
        repositories: repos,
        availablePlugins: available,
        availableUpdates: state.availableUpdates,
        installingPlugins: state.installingPlugins,
      );
    } catch (e) {
      state = ExtensionsError(
        e.toString(),
        installedPlugins: state.installedPlugins,
        repositories: state.repositories,
        availablePlugins: state.availablePlugins,
        availableUpdates: state.availableUpdates,
        installingPlugins: state.installingPlugins,
      );
    }
  }

  /// Fetches one repository and its plugin lists, or null if it is
  /// unreachable or malformed. A bad repository must not take the others down
  /// with it, which is why the catch is here rather than around [Future.wait].
  Future<({ExtensionRepository repo, List<ExtensionPlugin> plugins})?>
  _loadRepo(String url, RepositoryService repositoryService) async {
    try {
      final repo = await repositoryService.fetchRepository(url);
      if (repo == null) return null;
      return (
        repo: repo,
        plugins: await repositoryService.getRepoPlugins(repo),
      );
    } catch (e) {
      if (kDebugMode) debugPrint("Failed to load persisted repo $url: $e");
      return null;
    }
  }

  Future<void> loadInstalledPlugins() async {
    state = ExtensionsLoading(
      installedPlugins: state.installedPlugins,
      repositories: state.repositories,
      availablePlugins: state.availablePlugins,
      availableUpdates: state.availableUpdates,
      installingPlugins: state.installingPlugins,
    );
    try {
      final storageService = ref.read(pluginStorageServiceProvider);
      final plugins = await storageService.listInstalledPlugins();

      // Load Asset Plugins if enabled
      if (ref.read(settingsRepositoryProvider).getDevLoadAssets()) {
        final assetPlugins = await _loadAssetPlugins();
        if (kDebugMode) {
          debugPrint(
            "ExtensionsController: Loaded ${assetPlugins.length} asset plugins",
          );
        }
        plugins.addAll(assetPlugins);
      } else {
        if (kDebugMode) {
          debugPrint("ExtensionsController: Asset loading disabled");
        }
      }

      state = ExtensionsSuccess(
        installedPlugins: plugins,
        repositories: state.repositories,
        availablePlugins: state.availablePlugins,
        availableUpdates: state.availableUpdates,
        installingPlugins: state.installingPlugins,
      );
    } catch (e) {
      state = ExtensionsError(
        e.toString(),
        installedPlugins: state.installedPlugins,
        repositories: state.repositories,
        availablePlugins: state.availablePlugins,
        availableUpdates: state.availableUpdates,
        installingPlugins: state.installingPlugins,
      );
    }
  }

  Future<List<ExtensionPlugin>> _loadAssetPlugins() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final assets = manifest.listAssets();

      // Find all .json manifest files. Each manifest.json represents a plugin.
      final manifestFiles = assets
          .where(
            (key) => key.startsWith('assets/plugins/') && key.endsWith('.json'),
          )
          .toList();

      final plugins = <ExtensionPlugin>[];

      for (final configFile in manifestFiles) {
        final content = await rootBundle.loadString(configFile);
        // The .js file is expected to have the same name as the .json file
        final jsFile = configFile.replaceFirst('.json', '.js');

        final plugin = _parseJsonManifest(content, jsFile);
        if (plugin != null) {
          plugins.add(plugin);
        }
      }
      return plugins;
    } catch (e) {
      if (kDebugMode) debugPrint("Error loading asset plugins: $e");
      return [];
    }
  }

  ExtensionPlugin? _parseJsonManifest(String content, String jsFilePath) {
    try {
      final json = Map<String, dynamic>.from(jsonDecode(content) as Map);

      // Dart 3 Pattern Matching for manifest extraction
      final (packageName, id) = (
        json['packageName'] as String?,
        json['id'] as String?,
      );

      if (packageName == null && id == null) {
        json['packageName'] = "local.asset.${jsFilePath.split('/').last}";
      }

      // Apply .debug suffix for asset plugins
      if (jsFilePath.startsWith('assets/')) {
        final currentPkg = (json['packageName'] ?? json['id']).toString();
        if (!currentPkg.endsWith('.debug')) {
          json['packageName'] = "$currentPkg.debug";
        }
      }

      // Important: The sourceUrl for the provider is the .js file
      json['url'] = jsFilePath;

      return ExtensionPlugin.fromJson(json, 'LocalAssets');
    } catch (e) {
      if (kDebugMode) {
        debugPrint("Error parsing json manifest for $jsFilePath: $e");
      }
      return null;
    }
  }

  /// The launch-time update check, off the launch critical path and asking
  /// before it spends anything.
  ///
  /// Returns the display names of the plugins with an update waiting, or an
  /// empty list when the check did not run at all. Every early return here is
  /// a decision not to touch the network:
  ///
  ///  * no repositories persisted - nothing could ever be found;
  ///  * checked within [autoCheckInterval] - a relaunch is not news;
  ///  * a metered connection - manifests are small, but on a data plan small is
  ///    still the user's money spent on something they did not ask for. Opening
  ///    the Extensions screen still fetches: that is the user asking.
  ///
  /// [force] is what a deliberate, user-initiated refresh passes.
  Future<List<String>> autoCheckForUpdates({bool force = false}) async {
    final prefs = await SharedPreferences.getInstance();
    if ((prefs.getStringList(repoUrlsKey) ?? const <String>[]).isEmpty) {
      return const <String>[];
    }

    if (!force) {
      final last = prefs.getInt(lastAutoCheckKey);
      if (last != null) {
        // A negative age means the clock moved backwards; treat that as due
        // rather than as "checked in the future" and never check again.
        final age = DateTime.now().difference(
          DateTime.fromMillisecondsSinceEpoch(last),
        );
        if (!age.isNegative && age < autoCheckInterval) return const <String>[];
      }
      if (await ref.read(meteredConnectionProvider)()) return const <String>[];
    }

    await ensureInitialized();
    final pending = await checkForUpdates();
    await prefs.setInt(lastAutoCheckKey, DateTime.now().millisecondsSinceEpoch);
    return pending;
  }

  /// Records which installed plugins have a newer version published, in
  /// [ExtensionsState.availableUpdates]. Installs nothing.
  ///
  /// It used to download and install every one of them on the spot, called
  /// from the first post-frame callback of a cold start. Putting third-party
  /// executable JavaScript on someone's device is not a decision an app makes
  /// on their behalf while they wait for the home screen - so this now only
  /// finds them, and the Extensions screen's per-plugin update button, which
  /// already renders off this map, is where the consent happens.
  ///
  /// Returns the display names of the plugins with an update waiting.
  Future<List<String>> checkForUpdates() async {
    final updates = <String, ExtensionPlugin>{};
    final onlineMap = <String, ExtensionPlugin>{};

    for (final list in state.availablePlugins.values) {
      for (final plugin in list) {
        onlineMap[plugin.packageName] = plugin;
      }
    }

    for (final installed in state.installedPlugins) {
      final online = onlineMap[installed.packageName];
      if (online != null && online.version > installed.version) {
        updates[installed.packageName] = online;
      }
    }

    // Written even when empty, so a plugin the user has since updated by hand
    // stops advertising an update - but not when that would be a no-op state
    // churn, and not over an error state whose message is still on screen.
    final unchanged =
        updates.length == state.availableUpdates.length &&
        updates.keys.every(state.availableUpdates.containsKey);
    if (!unchanged && state is! ExtensionsError) {
      state = ExtensionsSuccess(
        installedPlugins: state.installedPlugins,
        repositories: state.repositories,
        availablePlugins: state.availablePlugins,
        availableUpdates: updates,
        installingPlugins: state.installingPlugins,
      );
    }

    return updates.values.map((plugin) => plugin.name).toList();
  }

  Future<void> addRepository(String url, {Set<String>? visitedUrls}) async {
    // Cycle Detection
    visitedUrls ??= {};
    if (visitedUrls.contains(url)) {
      if (kDebugMode) {
        debugPrint("Recursion detected: skipping repeated repo $url");
      }
      return;
    }
    visitedUrls.add(url);

    state = ExtensionsLoading(
      installedPlugins: state.installedPlugins,
      repositories: state.repositories,
      availablePlugins: state.availablePlugins,
      availableUpdates: state.availableUpdates,
      installingPlugins: state.installingPlugins,
    );
    try {
      final repositoryService = ref.read(repositoryServiceProvider);
      final repo = await repositoryService.fetchRepository(url);
      if (repo != null) {
        // Handle Recursive Repositories (Megarepo)
        if (repo.includedRepos.isNotEmpty) {
          if (kDebugMode) {
            debugPrint(
              "Repo ${repo.name} contains ${repo.includedRepos.length} included repos",
            );
          }
          for (final subRepoUrl in repo.includedRepos) {
            await addRepository(subRepoUrl, visitedUrls: visitedUrls);
          }

          // If the repo is PURELY a container (no plugin of its own),
          // do NOT add it to the list or persist it.
          if (repo.pluginLists.isEmpty) {
            state = ExtensionsSuccess(
              installedPlugins: state.installedPlugins,
              repositories: state.repositories,
              availablePlugins: state.availablePlugins,
              availableUpdates: state.availableUpdates,
              installingPlugins: state.installingPlugins,
            );
            return;
          }
        }

        final currentRepos = List<ExtensionRepository>.from(state.repositories);
        if (!currentRepos.any((element) => element.url == repo.url)) {
          currentRepos.add(repo);

          // Persist URL (Only top-level or unique ones)
          final prefs = await SharedPreferences.getInstance();
          final urls = prefs.getStringList(repoUrlsKey) ?? [];
          if (!urls.contains(url)) {
            urls.add(url);
            await prefs.setStringList(repoUrlsKey, urls);
          }
        }

        final plugins = await repositoryService.getRepoPlugins(repo);
        final currentAvailable = Map<String, List<ExtensionPlugin>>.from(
          state.availablePlugins,
        );
        currentAvailable[repo.url] = plugins;

        state = ExtensionsSuccess(
          repositories: currentRepos,
          availablePlugins: currentAvailable,
          installedPlugins: state.installedPlugins,
          availableUpdates: state.availableUpdates,
          installingPlugins: state.installingPlugins,
        );
      } else {
        if (kDebugMode) debugPrint("Failed to parse repository at $url");
        if (visitedUrls.length == 1) {
          state = ExtensionsError(
            "Failed to parse repository",
            installedPlugins: state.installedPlugins,
            repositories: state.repositories,
            availablePlugins: state.availablePlugins,
            availableUpdates: state.availableUpdates,
            installingPlugins: state.installingPlugins,
          );
        } else {
          state = ExtensionsSuccess(
            installedPlugins: state.installedPlugins,
            repositories: state.repositories,
            availablePlugins: state.availablePlugins,
            availableUpdates: state.availableUpdates,
            installingPlugins: state.installingPlugins,
          );
        }
      }
    } catch (e) {
      state = ExtensionsError(
        e.toString(),
        installedPlugins: state.installedPlugins,
        repositories: state.repositories,
        availablePlugins: state.availablePlugins,
        availableUpdates: state.availableUpdates,
        installingPlugins: state.installingPlugins,
      );
    }
  }

  Future<void> removeRepository(String url) async {
    try {
      final currentRepos = List<ExtensionRepository>.from(state.repositories);
      currentRepos.removeWhere((r) => r.url == url);

      final currentAvailable = Map<String, List<ExtensionPlugin>>.from(
        state.availablePlugins,
      );
      currentAvailable.remove(url);

      // Update State with Repo Removed (keeping installedPlugins intact)
      state = ExtensionsSuccess(
        installedPlugins: state.installedPlugins,
        repositories: currentRepos,
        availablePlugins: currentAvailable,
        availableUpdates: state.availableUpdates,
        installingPlugins: state.installingPlugins,
      );

      // Remove persistence
      final prefs = await SharedPreferences.getInstance();
      final urls = prefs.getStringList(repoUrlsKey) ?? [];
      urls.remove(url);
      await prefs.setStringList(repoUrlsKey, urls);

      // Reload installed plugins to update the UI
      await loadInstalledPlugins();
    } catch (e) {
      state = ExtensionsError(
        "Failed to remove repository: $e",
        installedPlugins: state.installedPlugins,
        repositories: state.repositories,
        availablePlugins: state.availablePlugins,
        availableUpdates: state.availableUpdates,
        installingPlugins: state.installingPlugins,
      );
    }
  }

  Future<void> installPlugin(ExtensionPlugin plugin) async {
    await installPlugins([plugin]);
  }

  Future<void> installPlugins(List<ExtensionPlugin> plugins) async {
    final newInstalling = Set<String>.from(state.installingPlugins);
    for (final p in plugins) {
      newInstalling.add(p.packageName);
    }

    state = ExtensionsSuccess(
      installedPlugins: state.installedPlugins,
      repositories: state.repositories,
      availablePlugins: state.availablePlugins,
      availableUpdates: state.availableUpdates,
      installingPlugins: newInstalling,
    );
    try {
      final repositoryService = ref.read(repositoryServiceProvider);
      final storageService = ref.read(pluginStorageServiceProvider);

      for (final plugin in plugins) {
        File? savedFile;

        // Standard HTTP Download
        savedFile = await repositoryService.downloadPlugin(plugin.sourceUrl);

        if (savedFile != null) {
          final installedPlugin = await storageService.installPlugin(
            savedFile.path,
            plugin.repositoryId,
          );
          final targetPlugin = installedPlugin ?? plugin;

          // Await ExtensionManager loading dynamic/static providers BEFORE stopping the spinner!
          try {
            await ref
                .read(extensionManagerProvider.notifier)
                .reloadPlugin(targetPlugin);
          } catch (e) {
            if (kDebugMode) {
              debugPrint("Error initializing plugin providers: $e");
            }
          }

          // Clear this plugin from availableUpdates
          final newUpdates = Map<String, ExtensionPlugin>.from(
            state.availableUpdates,
          )..remove(targetPlugin.packageName);

          final currentInstalling = Set<String>.from(state.installingPlugins)
            ..remove(targetPlugin.packageName);

          final newInstalled = List<ExtensionPlugin>.from(
            state.installedPlugins,
          );
          final existingIndex = newInstalled.indexWhere(
            (p) => p.packageName == targetPlugin.packageName,
          );
          if (existingIndex >= 0) {
            newInstalled[existingIndex] = targetPlugin;
          } else {
            newInstalled.add(targetPlugin);
          }

          state = ExtensionsSuccess(
            installedPlugins: newInstalled,
            repositories: state.repositories,
            availablePlugins: state.availablePlugins,
            availableUpdates: newUpdates,
            installingPlugins: currentInstalling,
          );

          if (await savedFile.exists()) {
            await savedFile.delete();
          }
        } else {
          // Download failed, remove from installing set
          final currentInstalling = Set<String>.from(state.installingPlugins)
            ..remove(plugin.packageName);
          state = ExtensionsSuccess(
            installedPlugins: state.installedPlugins,
            repositories: state.repositories,
            availablePlugins: state.availablePlugins,
            availableUpdates: state.availableUpdates,
            installingPlugins: currentInstalling,
          );
        }
      }
      await loadInstalledPlugins();
    } catch (e) {
      final currentInstalling = Set<String>.from(state.installingPlugins);
      for (final p in plugins) {
        currentInstalling.remove(p.packageName);
      }
      state = ExtensionsError(
        e.toString(),
        installedPlugins: state.installedPlugins,
        repositories: state.repositories,
        availablePlugins: state.availablePlugins,
        availableUpdates: state.availableUpdates,
        installingPlugins: currentInstalling,
      );
    }
  }

  Future<void> updatePlugin(ExtensionPlugin plugin) async {
    await installPlugin(plugin);
  }

  Future<void> uninstallPlugin(ExtensionPlugin plugin) async {
    final storageService = ref.read(pluginStorageServiceProvider);
    await storageService.deletePlugin(plugin);
    await loadInstalledPlugins();
  }
}
