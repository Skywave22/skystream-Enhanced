import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/logger/app_logger.dart';
import 'package:talker_flutter/talker_flutter.dart';

/// The log buffer is the app's only shipped diagnostic: `/logs` renders
/// `talker.history` and its share action exports the same list. Before this
/// existed the logger was `enabled: kDebugMode`, so a release build recorded
/// nothing at all and the screen a user was told to send us was blank.
///
/// Three properties have to hold in a *release* build, which is why
/// [createAppTalker] takes `releaseMode` instead of reading `kReleaseMode`
/// (a compile-time `false` anywhere a test can run):
///  * entries are still recorded,
///  * nothing reaches the console,
///  * the buffer cannot grow without bound over a long session.
void main() {
  group('release logging', () {
    test('records to the buffer but writes nothing to the console', () {
      final List<String> console = <String>[];
      final Talker logger = createAppTalker(
        releaseMode: true,
        output: console.add,
      );

      logger.info('playback started');
      logger.handle(StateError('decoder died'), StackTrace.current);

      expect(logger.history, hasLength(2));
      expect(_text(logger), contains('playback started'));
      expect(_text(logger), contains('decoder died'));
      expect(
        console,
        isEmpty,
        reason: 'release must stay silent; main() no-ops debugPrint anyway',
      );
    });

    test('debug builds still write to the console', () {
      final List<String> console = <String>[];
      final Talker logger = createAppTalker(
        releaseMode: false,
        output: console.add,
      );

      logger.info('playback started');

      expect(console, isNotEmpty);
    });

    test('the app-wide logger is enabled regardless of build mode', () {
      expect(talker.settings.enabled, isTrue);
      expect(talker.settings.useHistory, isTrue);
      expect(talker.settings.maxHistoryItems, kAppLogHistoryLimit);
    });
  });

  group('bounded buffer', () {
    test('keeps at most kAppLogHistoryLimit entries', () {
      final Talker logger = createAppTalker(
        releaseMode: true,
        output: (String _) {},
      );

      for (int i = 0; i < kAppLogHistoryLimit + 120; i++) {
        logger.info('entry $i');
      }

      expect(logger.history, hasLength(kAppLogHistoryLimit));
      // A ring buffer, so it is the newest entries that survive.
      expect(_text(logger), contains('entry ${kAppLogHistoryLimit + 119}'));
      expect(_text(logger), isNot(contains('entry 0 ')));
    });

    test('truncates a single oversized entry', () {
      final Talker logger = createAppTalker(
        releaseMode: true,
        output: (String _) {},
      );

      logger.info('x' * (kAppLogMessageLimit * 5));

      final String? stored = logger.history.single.message;
      expect(stored, isNotNull);
      expect(stored!.length, lessThan(kAppLogMessageLimit + 64));
      expect(stored, endsWith('[truncated]'));
    });
  });

  group('redaction', () {
    test('strips an api key out of a logged URL', () {
      final Talker logger = createAppTalker(
        releaseMode: true,
        output: (String _) {},
      );

      logger.debug(
        '[JS HTTP] GET https://api.themoviedb.org/3/movie/550'
        '?api_key=abc123def456secret&language=en-US',
      );

      final String text = _text(logger);
      expect(text, isNot(contains('abc123def456secret')));
      expect(text, contains(kRedactedPlaceholder));
      expect(text, contains('language=en-US'), reason: 'only the key goes');
    });

    test('strips bearer tokens and JWTs', () {
      final Talker logger = createAppTalker(
        releaseMode: true,
        output: (String _) {},
      );

      logger.error(
        'auth failed: Bearer abcdefgh12345678 / '
        'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.QWxhZGRpbg',
      );

      final String text = _text(logger);
      expect(text, isNot(contains('abcdefgh12345678')));
      expect(text, isNot(contains('eyJhbGciOiJIUzI1NiJ9')));
      expect(text, contains(kRedactedPlaceholder));
    });

    test('strips a secret carried by the exception rather than the message',
        () {
      final Talker logger = createAppTalker(
        releaseMode: true,
        output: (String _) {},
      );

      logger.handle(
        Exception('403 for https://api.opensubtitles.com/api/v1/subtitles'
            '?apikey=topsecretvalue'),
        StackTrace.current,
        'subtitle search failed',
      );

      final String text = _text(logger);
      expect(text, isNot(contains('topsecretvalue')));
      expect(text, contains(kRedactedPlaceholder));
    });

    test('leaves a clean entry untouched, type and all', () {
      final Talker logger = createAppTalker(
        releaseMode: true,
        output: (String _) {},
      );

      logger.handle(StateError('nothing secret here'), StackTrace.current);

      // /logs colours and filters by the concrete subclass, so an entry that
      // needed no redaction must not be rewritten into a plain TalkerLog.
      expect(logger.history.single, isA<TalkerError>());
      expect(_text(logger), contains('nothing secret here'));
    });

    test('the app-wide logger redacts too', () {
      talker.cleanHistory();
      addTearDown(talker.cleanHistory);

      talker.info('sync: https://api.trakt.tv/sync?access_token=live-token-xyz');

      final String text = _text(talker);
      expect(text, isNot(contains('live-token-xyz')));
      expect(text, contains(kRedactedPlaceholder));
    });
  });

  group('redactSecrets', () {
    test('is a no-op on ordinary text', () {
      const String plain = 'Bootstrap: loaded 12 extensions in 340 ms';
      expect(redactSecrets(plain), plain);
    });

    test('stays fast on a long line with nothing to redact', () {
      // An unbounded quantifier in front of the keyword alternation backtracks
      // quadratically: measured at 8.3 s for this input, on the UI thread.
      final String haystack = 'x' * 20000;
      final Stopwatch sw = Stopwatch()..start();
      final String out = redactSecrets(haystack);
      sw.stop();

      expect(out, haystack);
      expect(
        sw.elapsedMilliseconds,
        lessThan(1000),
        reason: 'redaction runs on the UI thread for every log entry',
      );
    });

    test('handles every credential shape in one line', () {
      final String out = redactSecrets(
        'GET /x?api_key=AAA&token=BBB "client_secret": "CCC" '
        'Authorization: Bearer DDDDDDDDDD',
      );
      for (final String secret in <String>['AAA', 'BBB', 'CCC', 'DDDDDDDDDD']) {
        expect(out, isNot(contains(secret)), reason: out);
      }
    });
  });
}

String _text(Talker logger) =>
    logger.history.map((TalkerData e) => e.generateTextMessage()).join('\n');
