import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/search/data/search_history_store.dart';
import 'package:skystream/features/search/presentation/search_history_provider.dart';

/// The settings box, standing in as a list.
class _FakeStore implements SearchHistoryStore {
  List<String> queries;
  int writes = 0;

  _FakeStore([this.queries = const []]);

  @override
  List<String> read() => queries;

  @override
  Future<void> write(List<String> next) async {
    writes++;
    queries = List<String>.from(next);
  }
}

void main() {
  late _FakeStore store;

  ProviderContainer containerWith(_FakeStore fake) {
    final container = ProviderContainer(
      overrides: [searchHistoryStoreProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() => store = _FakeStore());

  group('SearchHistory.build', () {
    test('hydrates from the store', () {
      final container = containerWith(_FakeStore(['Dune', 'Arrival']));

      expect(container.read(searchHistoryProvider), ['Dune', 'Arrival']);
    });

    test('is empty when nothing is stored', () {
      expect(containerWith(store).read(searchHistoryProvider), isEmpty);
    });
  });

  group('SearchHistory.add', () {
    test('puts the newest query first', () async {
      final container = containerWith(store);
      final history = container.read(searchHistoryProvider.notifier);

      await history.add('Dune');
      await history.add('Arrival');

      expect(container.read(searchHistoryProvider), ['Arrival', 'Dune']);
    });

    test('persists every change', () async {
      final container = containerWith(store);
      final history = container.read(searchHistoryProvider.notifier);

      await history.add('Dune');
      await history.add('Arrival');

      expect(store.queries, ['Arrival', 'Dune']);
    });

    test('trims surrounding whitespace', () async {
      final container = containerWith(store);

      await container.read(searchHistoryProvider.notifier).add('  Dune  ');

      expect(container.read(searchHistoryProvider), ['Dune']);
    });

    test('ignores a whitespace-only query', () async {
      final container = containerWith(store);

      await container.read(searchHistoryProvider.notifier).add('   ');

      expect(container.read(searchHistoryProvider), isEmpty);
      expect(store.writes, 0);
    });

    // A repeat is the common case - the user searches the same show every
    // evening - and it must not grow the list or leave the entry buried.
    test(
      'moves a repeated query to the front instead of duplicating it',
      () async {
        final container = containerWith(store);
        final history = container.read(searchHistoryProvider.notifier);

        await history.add('Dune');
        await history.add('Arrival');
        await history.add('Dune');

        expect(container.read(searchHistoryProvider), ['Dune', 'Arrival']);
      },
    );

    test(
      'treats casing as the same query and keeps the latest casing',
      () async {
        final container = containerWith(store);
        final history = container.read(searchHistoryProvider.notifier);

        await history.add('Dune');
        await history.add('dune');

        expect(container.read(searchHistoryProvider), ['dune']);
      },
    );

    test(
      'skips the write when re-adding the query already at the front',
      () async {
        final container = containerWith(store);
        final history = container.read(searchHistoryProvider.notifier);

        await history.add('Dune');
        await history.add('Dune');

        expect(store.writes, 1);
      },
    );

    test('caps the stored list at $kMaxStoredSearchHistory entries', () async {
      final container = containerWith(store);
      final history = container.read(searchHistoryProvider.notifier);

      for (var i = 0; i <= kMaxStoredSearchHistory; i++) {
        await history.add('query $i');
      }

      final stored = container.read(searchHistoryProvider);
      expect(stored, hasLength(kMaxStoredSearchHistory));
      expect(stored.first, 'query $kMaxStoredSearchHistory');
      expect(stored, isNot(contains('query 0')));
    });
  });

  group('SearchHistory.remove', () {
    test('drops the matching entry and leaves the rest ordered', () async {
      final container = containerWith(_FakeStore(['Dune', 'Arrival', 'Alien']));

      await container.read(searchHistoryProvider.notifier).remove('Arrival');

      expect(container.read(searchHistoryProvider), ['Dune', 'Alien']);
    });

    test('matches regardless of casing', () async {
      final container = containerWith(_FakeStore(['Dune']));

      await container.read(searchHistoryProvider.notifier).remove('DUNE');

      expect(container.read(searchHistoryProvider), isEmpty);
    });

    test('skips the write when nothing matched', () async {
      final container = containerWith(store);
      store.queries = ['Dune'];

      await container.read(searchHistoryProvider.notifier).remove('Arrival');

      expect(store.writes, 0);
    });
  });

  group('SearchHistory.clear', () {
    test('empties the list and the store', () async {
      final fake = _FakeStore(['Dune', 'Arrival']);
      final container = containerWith(fake);

      await container.read(searchHistoryProvider.notifier).clear();

      expect(container.read(searchHistoryProvider), isEmpty);
      expect(fake.queries, isEmpty);
    });

    test('skips the write when already empty', () async {
      final container = containerWith(store);

      await container.read(searchHistoryProvider.notifier).clear();

      expect(store.writes, 0);
    });
  });

  group('matchingSearchHistory', () {
    const history = ['Mad Max', 'Batman', 'Marriage Story', 'Dune'];

    test('returns the head of the list for an empty query', () {
      expect(matchingSearchHistory(history, '', limit: 2), [
        'Mad Max',
        'Batman',
      ]);
    });

    test('treats a whitespace-only query as empty', () {
      expect(matchingSearchHistory(history, '  ', limit: 1), ['Mad Max']);
    });

    // "ma" prefixes "Mad Max" and "Marriage Story" but only sits inside
    // "Batman" - the two the user is likelier to mean come first.
    test('ranks prefix matches above substring matches', () {
      expect(matchingSearchHistory(history, 'ma', limit: 10), [
        'Mad Max',
        'Marriage Story',
        'Batman',
      ]);
    });

    test('keeps recency order within a tier', () {
      expect(matchingSearchHistory(history, 'mar', limit: 10), [
        'Marriage Story',
      ]);
    });

    test('ignores casing on both sides', () {
      expect(matchingSearchHistory(history, 'DUNE', limit: 10), ['Dune']);
    });

    test('honours the limit', () {
      expect(matchingSearchHistory(history, 'ma', limit: 1), ['Mad Max']);
    });

    test('returns nothing for a zero limit', () {
      expect(matchingSearchHistory(history, 'ma', limit: 0), isEmpty);
    });

    test('returns nothing when no entry matches', () {
      expect(matchingSearchHistory(history, 'zzz', limit: 10), isEmpty);
    });
  });

  group('withoutDuplicatedHistory', () {
    test('drops suggestions already shown as recents, ignoring casing', () {
      expect(
        withoutDuplicatedHistory(
          ['Dune', 'Dune: Part Two', 'Arrival'],
          ['dune'],
        ),
        ['Dune: Part Two', 'Arrival'],
      );
    });

    test('passes suggestions through when there are no recents', () {
      expect(withoutDuplicatedHistory(['Dune'], const []), ['Dune']);
    });
  });
}
