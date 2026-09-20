/// The app honours no launch arguments.
///
/// Full screen mode once had `--full-screen` (and the retired `--big-picture`
/// spellings beside it), which existed for internal testing on a desktop wired
/// to a television and reached master by accident. Nothing in the shipped
/// product documented them, only three of the five platforms can pass an
/// argument at all, and the state they set is now a remembered setting - so
/// the flag bought nothing a user could reach and quietly made the desktop
/// build behave differently from the phone and the television.
///
/// A source guard rather than a behavioural test: the point is that no code
/// path reads process arguments, and the way that regresses is someone adding
/// a second flag somewhere else entirely.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Every Dart file the app ships, generated localisations excluded.
  List<File> libSources() {
    final lib = Directory('lib');
    expect(
      lib.existsSync(),
      isTrue,
      reason: 'run this from the package root so lib/ resolves',
    );
    return lib
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !f.path.contains('l10n'))
        .toList();
  }

  String relative(File f) =>
      f.path.replaceAll(Platform.pathSeparator, '/');

  test('the full screen flags are gone from lib/', () {
    // Named one by one rather than matching `--anything`: libVLC takes its own
    // options as strings of the same shape (`--http-reconnect` in
    // vlc_player_screen.dart), and those are arguments to the media engine,
    // not flags read off this process.
    final retired = RegExp(
      r"'--(full-screen|fullscreen|big-picture|bigpicture)'",
    );

    final hits = <String>[];
    for (final file in libSources()) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (retired.hasMatch(lines[i])) {
          hits.add('${relative(file)}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }

    expect(
      hits,
      isEmpty,
      reason:
          'A launch flag is reachable on desktop only, so anything it '
          'controls is a feature three platforms have and two do not. Full '
          'screen mode is a setting; it needs no flag.\n${hits.join('\n')}',
    );
  });

  test('nothing in lib/ reads the process arguments', () {
    // The general form of the rule. Whatever the flag is spelled, it can only
    // be honoured by reading the argument list, so guard the read instead of
    // trying to enumerate every future spelling.
    final reads = RegExp(r'executableArguments|appLaunchArgs');

    final hits = <String>[];
    for (final file in libSources()) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (reads.hasMatch(lines[i])) {
          hits.add('${relative(file)}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }

    expect(hits, isEmpty, reason: hits.join('\n'));
  });

  test('main takes no arguments, so none can be forwarded', () {
    final main = File('lib/main.dart');
    expect(main.existsSync(), isTrue);
    final source = main.readAsStringSync();

    expect(
      source,
      isNot(contains('void main(List<String>')),
      reason:
          'taking the argument list is the first half of honouring it; with '
          'no flags left there is nothing to take',
    );
    expect(
      source,
      isNot(contains('appLaunchArgs')),
      reason: 'the process arguments are no longer parked for anyone to read',
    );
  });
}
