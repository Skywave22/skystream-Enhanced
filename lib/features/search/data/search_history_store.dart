import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/storage/settings_repository.dart';

part 'search_history_store.g.dart';

/// Where recent search queries are kept.
///
/// A two-method seam over the settings box. It exists so [SearchHistory] can
/// be driven by a list in memory under test - the alternative is standing up
/// Hive, a temp directory and the whole [SettingsRepository] surface to
/// exercise "does a repeated query move to the front".
abstract class SearchHistoryStore {
  /// The stored queries, most-recent-first. Empty when nothing is stored.
  List<String> read();

  Future<void> write(List<String> queries);
}

class SettingsSearchHistoryStore implements SearchHistoryStore {
  final SettingsRepository _repository;

  const SettingsSearchHistoryStore(this._repository);

  @override
  List<String> read() => _repository.getSearchHistory();

  @override
  Future<void> write(List<String> queries) =>
      _repository.setSearchHistory(queries);
}

@Riverpod(keepAlive: true)
SearchHistoryStore searchHistoryStore(Ref ref) {
  return SettingsSearchHistoryStore(ref.watch(settingsRepositoryProvider));
}
