import 'package:collection/collection.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'explore_mode_provider.g.dart';

const String _kExploreModeKey = 'explore_mode_type';

enum ExploreModeType { movies, anime, stremio }

// App-wide user state that persists to SharedPreferences. Disposing it would
// snap the mode back to `movies` and re-read prefs asynchronously; the
// keepAlive `genres` provider watching it is the only reason that never
// happened.
@Riverpod(keepAlive: true)
class ExploreMode extends _$ExploreMode {
  @override
  ExploreModeType build() {
    _loadPersistedMode();
    return ExploreModeType.movies;
  }

  Future<void> _loadPersistedMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedMode = prefs.getString(_kExploreModeKey);
      if (savedMode != null) {
        final matched = ExploreModeType.values.firstWhereOrNull(
          (e) => e.name == savedMode,
        );
        if (matched != null && state != matched) {
          state = matched;
        }
      } else {
        // Backward compatibility for old boolean key
        final oldBool = prefs.getBool('explore_mode_is_anime');
        if (oldBool == true && state != ExploreModeType.anime) {
          state = ExploreModeType.anime;
        }
      }
    } catch (_) {}
  }

  void setMode(ExploreModeType mode) {
    state = mode;
    _persistMode(mode);
  }

  void setAnimeMode(bool isAnime) {
    setMode(isAnime ? ExploreModeType.anime : ExploreModeType.movies);
  }

  Future<void> _persistMode(ExploreModeType mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kExploreModeKey, mode.name);
    } catch (_) {}
  }
}
