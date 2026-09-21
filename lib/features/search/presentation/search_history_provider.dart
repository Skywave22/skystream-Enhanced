import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../data/search_history_store.dart';

part 'search_history_provider.g.dart';

/// How many queries are kept on disk.
///
/// Well past what any list shows; the surplus is what makes a query typed
/// weeks ago still match once the user starts typing it again.
const int kMaxStoredSearchHistory = 50;

/// How many recents to show when the field is empty.
const int kSearchHistoryEmptyFieldLimit = 10;

/// How many recents to pin above the network suggestions while typing.
///
/// Deliberately small: the suggestions underneath are the reason the user is
/// typing, and a long block of history pushes them off the screen.
const int kSearchHistoryTypingLimit = 4;

/// Recent search queries, most-recent-first, shared by every search surface.
///
/// One list rather than one per surface, so a title looked up in Explore is
/// offered again in the search tab. The surfaces query different backends, so
/// a recent can come back empty where it was never run - the same tradeoff
/// YouTube makes across its own surfaces, and worth it for not making the
/// user retype.
@Riverpod(keepAlive: true)
class SearchHistory extends _$SearchHistory {
  @override
  List<String> build() => ref.watch(searchHistoryStoreProvider).read();

  /// Records [query] as the most recent search.
  ///
  /// Whitespace-only queries are dropped. A repeat moves to the front and
  /// keeps the casing just typed, so re-searching "dune" after "Dune" leaves
  /// one row reading "dune" rather than two rows differing only in case.
  ///
  /// State is updated before the write so the list is correct on the next
  /// frame; the disk write is awaited but nothing renders off the back of it.
  Future<void> add(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;

    final folded = trimmed.toLowerCase();
    final next = <String>[
      trimmed,
      ...state.where((entry) => entry.toLowerCase() != folded),
    ];
    if (next.length > kMaxStoredSearchHistory) {
      next.removeRange(kMaxStoredSearchHistory, next.length);
    }

    if (_isSameList(next, state)) return;
    state = List.unmodifiable(next);
    await ref.read(searchHistoryStoreProvider).write(next);
  }

  /// Drops [query] from the history. Matching is case-insensitive, so the row
  /// the user tapped is the row that goes, whatever casing it was stored in.
  Future<void> remove(String query) async {
    final folded = query.trim().toLowerCase();
    final next = state
        .where((entry) => entry.toLowerCase() != folded)
        .toList(growable: false);

    if (next.length == state.length) return;
    state = List.unmodifiable(next);
    await ref.read(searchHistoryStoreProvider).write(next);
  }

  /// Clears every stored query.
  Future<void> clear() async {
    if (state.isEmpty) return;
    state = const [];
    await ref.read(searchHistoryStoreProvider).write(const []);
  }

  static bool _isSameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The recents to show for [query], newest-first within each tier.
///
/// Entries starting with the query come before entries merely containing it:
/// having typed "ma", "Mad Max" is a likelier target than "Batman". Recency
/// breaks ties inside a tier because [SearchHistory] already stores in that
/// order.
///
/// An empty [query] returns the head of the list unfiltered, which is what
/// the field-empty state shows.
List<String> matchingSearchHistory(
  List<String> history,
  String query, {
  required int limit,
}) {
  if (limit <= 0) return const [];

  final folded = query.trim().toLowerCase();
  if (folded.isEmpty) {
    return history.take(limit).toList(growable: false);
  }

  final prefixMatches = <String>[];
  final containsMatches = <String>[];
  for (final entry in history) {
    final entryFolded = entry.toLowerCase();
    if (entryFolded.startsWith(folded)) {
      prefixMatches.add(entry);
    } else if (entryFolded.contains(folded)) {
      containsMatches.add(entry);
    }
  }

  return [
    ...prefixMatches,
    ...containsMatches,
  ].take(limit).toList(growable: false);
}

/// [suggestions] with anything already shown as a recent removed.
///
/// Without this the same title appears twice a few pixels apart - once under
/// a clock icon and once under a magnifier - which reads as a bug.
List<String> withoutDuplicatedHistory(
  List<String> suggestions,
  List<String> shownHistory,
) {
  if (shownHistory.isEmpty) return suggestions;
  final folded = shownHistory.map((e) => e.toLowerCase()).toSet();
  return suggestions
      .where((s) => !folded.contains(s.toLowerCase()))
      .toList(growable: false);
}
