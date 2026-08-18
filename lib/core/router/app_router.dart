import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:go_router/go_router.dart';
import 'package:skystream/features/home/presentation/home_screen.dart';
import 'package:skystream/features/search/presentation/search_screen.dart';
import '../../features/explore/presentation/explore_screen.dart';
import 'package:skystream/features/library/presentation/library_screen.dart';
import 'package:skystream/features/addons/presentation/addons_screen.dart';
import 'package:skystream/features/addons/presentation/addon_detail_screen.dart';
import 'package:skystream/features/addons/presentation/addon_catalog_screen.dart';
import 'package:skystream/features/settings/presentation/settings_screen.dart';
import '../../features/extensions/screens/extensions_screen.dart';
import '../../features/settings/presentation/developer_options_screen.dart';
import '../../features/details/presentation/details_screen.dart';
import '../../features/details/presentation/tmdb_movie_details_screen.dart';
import '../../features/explore/presentation/view_all_screen.dart';
import '../../features/player/presentation/player_screen.dart';
import '../../features/player/presentation/addon_player_screen.dart';
import '../../core/addons/models/addon_stream.dart';
import '../domain/entity/multimedia_item.dart';
import 'package:skystream/shared/widgets/app_scaffold.dart';
import '../../core/storage/settings_repository.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:flutter/foundation.dart';
import '../logger/app_logger.dart';

part 'app_router.g.dart';

// --- Route Data Classes ---

@TypedStatefulShellRoute<AppShellRouteData>(
  branches: [
    TypedStatefulShellBranch<HomeBranchData>(
      routes: [TypedGoRoute<HomeRoute>(path: '/home')],
    ),
    TypedStatefulShellBranch<SearchBranchData>(
      routes: [TypedGoRoute<SearchRoute>(path: '/search')],
    ),
    TypedStatefulShellBranch<ExploreBranchData>(
      routes: [TypedGoRoute<ExploreRoute>(path: '/explore')],
    ),
    TypedStatefulShellBranch<LibraryBranchData>(
      routes: [TypedGoRoute<LibraryRoute>(path: '/library')],
    ),
    TypedStatefulShellBranch<AddonsBranchData>(
      routes: [TypedGoRoute<AddonsRoute>(path: '/addons')],
    ),
    TypedStatefulShellBranch<SettingsBranchData>(
      routes: [
        TypedGoRoute<SettingsRoute>(
          path: '/settings',
          routes: [
            TypedGoRoute<ExtensionsRoute>(path: 'extensions'),
            TypedGoRoute<DeveloperOptionsRoute>(path: 'developer'),
          ],
        ),
      ],
    ),
  ],
)
class AppShellRouteData extends StatefulShellRouteData {
  const AppShellRouteData();

  @override
  Widget builder(
    BuildContext context,
    GoRouterState state,
    StatefulNavigationShell navigationShell,
  ) {
    return AppScaffold(navigationShell: navigationShell);
  }
}

class HomeBranchData extends StatefulShellBranchData {
  const HomeBranchData();
}

class HomeRoute extends GoRouteData with $HomeRoute {
  const HomeRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) => const HomeScreen();
}

class SearchBranchData extends StatefulShellBranchData {
  const SearchBranchData();
}

class SearchRoute extends GoRouteData with $SearchRoute {
  const SearchRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const SearchScreen();
}

class ExploreBranchData extends StatefulShellBranchData {
  const ExploreBranchData();
}

class ExploreRoute extends GoRouteData with $ExploreRoute {
  const ExploreRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const ExploreScreen();
}

class LibraryBranchData extends StatefulShellBranchData {
  const LibraryBranchData();
}

class LibraryRoute extends GoRouteData with $LibraryRoute {
  const LibraryRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const LibraryScreen();
}

class AddonsBranchData extends StatefulShellBranchData {
  const AddonsBranchData();
}

class AddonsRoute extends GoRouteData with $AddonsRoute {
  const AddonsRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const AddonsScreen();
}

class SettingsBranchData extends StatefulShellBranchData {
  const SettingsBranchData();
}

class SettingsRoute extends GoRouteData with $SettingsRoute {
  const SettingsRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const SettingsScreen();
}

// --- Sub-routes of Settings ---

class ExtensionsRoute extends GoRouteData with $ExtensionsRoute {
  const ExtensionsRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const ExtensionsScreen();
}

class DeveloperOptionsRoute extends GoRouteData with $DeveloperOptionsRoute {
  const DeveloperOptionsRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const DeveloperOptionsScreen();
}

@TypedGoRoute<AppLogsRoute>(path: '/logs')
class AppLogsRoute extends GoRouteData with $AppLogsRoute {
  const AppLogsRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) {
    return TalkerScreen(
      talker: talker,
      theme: TalkerScreenTheme(
        backgroundColor: Theme.of(context).colorScheme.surface,
        textColor: Theme.of(context).colorScheme.onSurface,
        cardColor: Theme.of(context).colorScheme.surface,
      ),
    );
  }
}

// --- Typed Extras ---

class DetailsRouteExtra {
  const DetailsRouteExtra({required this.item, this.autoPlay = false});
  final MultimediaItem item;
  final bool autoPlay;
}

class PlayerRouteExtra {
  const PlayerRouteExtra({
    required this.item,
    required this.videoUrl,
    this.episode,
    this.preloadedStreams,
  });
  final MultimediaItem item;
  final String videoUrl;
  final Episode? episode;

  /// Cross-plugin stream links aggregated before opening the player. When
  /// present, the player does not call loadStreams again for this item/episode.
  final List<StreamResult>? preloadedStreams;
}

class ViewAllRouteExtra {
  const ViewAllRouteExtra({
    required this.title,
    required this.initialMediaList,
    required this.category,
    this.onTap,
  });
  final String title;
  final List<MultimediaItem> initialMediaList;
  final ViewAllCategory category;
  final void Function(MultimediaItem item)? onTap;
}

// --- Full Screen Routes ---

@TypedGoRoute<DetailsRoute>(path: '/details')
class DetailsRoute extends GoRouteData with $DetailsRoute {
  const DetailsRoute({required this.$extra});
  final DetailsRouteExtra $extra;

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return DetailsScreen(item: $extra.item, autoPlay: $extra.autoPlay);
  }
}

@TypedGoRoute<TmdbDetailsRoute>(path: '/tmdb-details')
class TmdbDetailsRoute extends GoRouteData with $TmdbDetailsRoute {
  const TmdbDetailsRoute({
    required this.movieId,
    this.mediaType = 'movie',
    this.heroTag,
    this.placeholderPoster,
    this.source,
  });
  final int movieId;
  final String mediaType;
  final String? heroTag;
  final String? placeholderPoster;
  final String? source;

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return TmdbMovieDetailsScreen(
      movieId: movieId,
      mediaType: mediaType,
      heroTag: heroTag,
      placeholderPoster: placeholderPoster,
      source: source,
    );
  }
}

@TypedGoRoute<ViewAllRoute>(path: '/view-all')
class ViewAllRoute extends GoRouteData with $ViewAllRoute {
  const ViewAllRoute({required this.$extra});
  final ViewAllRouteExtra $extra;

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return ViewAllScreen(
      title: $extra.title,
      initialMediaList: $extra.initialMediaList,
      category: $extra.category,
      onTap: $extra.onTap,
    );
  }
}

@TypedGoRoute<PlayerRoute>(path: '/player')
class PlayerRoute extends GoRouteData with $PlayerRoute {
  const PlayerRoute({required this.$extra});
  final PlayerRouteExtra $extra;

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return PlayerScreen(
      item: $extra.item,
      videoUrl: $extra.videoUrl,
      episode: $extra.episode,
      preloadedStreams: $extra.preloadedStreams,
    );
  }
}


/// Payload for the dedicated add-on player. The full candidate list travels
/// with the route so in-player source switching never needs a refetch.
class AddonPlayerRouteExtra {
  const AddonPlayerRouteExtra({
    required this.item,
    required this.streams,
    this.episode,
    this.initialIndex = 0,
    this.type = 'movie',
    this.contentId,
    this.videoId,
  });
  final MultimediaItem item;
  final List<AddonStream> streams;
  final Episode? episode;
  final int initialIndex;

  /// Stremio type/ids so the player can ask add-ons for subtitles.
  final String type;
  final String? contentId;
  final String? videoId;
}

@TypedGoRoute<AddonDetailRoute>(path: '/addon-detail')
class AddonDetailRoute extends GoRouteData with $AddonDetailRoute {
  const AddonDetailRoute({
    required this.type,
    required this.id,
    this.addonId,
  });
  final String type;
  final String id;
  final String? addonId;

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return AddonDetailScreen(type: type, id: id, addonId: addonId);
  }
}

@TypedGoRoute<AddonCatalogRoute>(path: '/addon-catalog')
class AddonCatalogRoute extends GoRouteData with $AddonCatalogRoute {
  const AddonCatalogRoute({
    required this.addonId,
    required this.type,
    required this.catalogId,
    required this.title,
  });
  final String addonId;
  final String type;
  final String catalogId;
  final String title;

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return AddonCatalogScreen(
      addonId: addonId,
      type: type,
      catalogId: catalogId,
      title: title,
    );
  }
}

@TypedGoRoute<AddonPlayerRoute>(path: '/addon-player')
class AddonPlayerRoute extends GoRouteData with $AddonPlayerRoute {
  const AddonPlayerRoute({required this.$extra});
  final AddonPlayerRouteExtra $extra;

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return AddonPlayerScreen(
      item: $extra.item,
      episode: $extra.episode,
      streams: $extra.streams,
      initialIndex: $extra.initialIndex,
      type: $extra.type,
      contentId: $extra.contentId,
      videoId: $extra.videoId,
    );
  }
}

// --- GoRouter Definition ---

final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Branch roots the shell can start on. `/stream` was removed in favour of
/// `/addons`, so a stale saved preference must be migrated instead of blowing
/// up GoRouter with an unknown initial location.
const List<String> kShellBranchRoutes = [
  '/home',
  '/search',
  '/explore',
  '/library',
  '/addons',
  '/settings',
];

@Riverpod(keepAlive: true)
GoRouter appRouter(Ref ref) {
  final saved = ref.read(settingsRepositoryProvider).getDefaultHomeScreen();
  final initial = kShellBranchRoutes.contains(saved)
      ? saved
      : (saved == '/stream' ? '/addons' : '/home');

  return GoRouter(
    initialLocation: initial,
    navigatorKey: rootNavigatorKey,
    debugLogDiagnostics: kDebugMode,
    routes: $appRoutes,
  );
}

// End of Routes
