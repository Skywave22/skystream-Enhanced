/// The run-time diagnostic switches, and the one property that matters about
/// them: a normal launch has to behave exactly as it did.
///
/// These exist to be turned on by a person following pasted instructions on a
/// machine nobody here owns, so the parsing is deliberately generous about what
/// counts as "on" and deliberately strict about everything else. A switch that
/// could be tripped by an unrelated variable, an empty string or a stray `0`
/// would put a diagnostic build into the hands of every user.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/player_debug_flags.dart';

void main() {
  setUp(() {
    addTearDown(() => PlayerDiagnostics.environment = const <String, String>{});
  });

  void env(Map<String, String> values) =>
      PlayerDiagnostics.environment = values;

  group('every switch is off unless it is asked for', () {
    test('an empty environment turns nothing on', () {
      env(const <String, String>{});
      expect(PlayerDiagnostics.verboseVlcLog, isFalse);
      expect(PlayerDiagnostics.suppressVideoSurface, isFalse);
    });

    // The failure mode worth guarding: a shell that exports a variable with an
    // empty value, or a tester who typed the name to "unset" it, must not be
    // shipping a suppressed video surface.
    test('a set-but-empty or zero value is off', () {
      for (final value in const <String>['', ' ', '0', 'false', 'no', 'off']) {
        env(<String, String>{
          'SKYSTREAM_VLC_VERBOSE': value,
          'SKYSTREAM_NO_VIDEO': value,
        });
        expect(
          PlayerDiagnostics.verboseVlcLog,
          isFalse,
          reason: '"$value" must not read as on',
        );
        expect(PlayerDiagnostics.suppressVideoSurface, isFalse);
      }
    });

    test('an unrelated variable turns nothing on', () {
      env(const <String, String>{'VLC_VERBOSE': '2', 'NO_VIDEO': '1'});
      expect(PlayerDiagnostics.verboseVlcLog, isFalse);
      expect(PlayerDiagnostics.suppressVideoSurface, isFalse);
    });
  });

  group('what a person can reasonably type is accepted', () {
    test('the four spellings of yes', () {
      for (final value in const <String>['1', 'true', 'yes', 'on']) {
        env(<String, String>{'SKYSTREAM_VLC_VERBOSE': value});
        expect(
          PlayerDiagnostics.verboseVlcLog,
          isTrue,
          reason: '"$value" has to read as on',
        );
      }
    });

    test('case and surrounding whitespace do not matter', () {
      env(const <String, String>{'SKYSTREAM_NO_VIDEO': ' TRUE '});
      expect(PlayerDiagnostics.suppressVideoSurface, isTrue);
    });
  });

  // The two are independent because the bisection depends on it: the run that
  // suppresses the video surface is the run whose libVLC log has to be read.
  test('the switches do not imply each other', () {
    env(const <String, String>{'SKYSTREAM_NO_VIDEO': '1'});
    expect(PlayerDiagnostics.suppressVideoSurface, isTrue);
    expect(PlayerDiagnostics.verboseVlcLog, isFalse);

    env(const <String, String>{'SKYSTREAM_VLC_VERBOSE': '1'});
    expect(PlayerDiagnostics.verboseVlcLog, isTrue);
    expect(PlayerDiagnostics.suppressVideoSurface, isFalse);
  });
}
