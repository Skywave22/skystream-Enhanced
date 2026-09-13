import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Windows hand-off used to end in
/// `Process.run('cmd', ['/c', 'start', '', '"$videoUrl"'], runInShell: true)`.
///
/// The URL in that string is produced by an add-on or a scraper plugin, i.e.
/// by third-party code. Dart quotes Windows process arguments for the C
/// runtime's parser and cmd.exe re-parses the joined command line afterwards
/// with different rules, so a `"` in the URL closes the quoted span and `&`,
/// `|` or `%NAME%` after it are read by the shell rather than by the player -
/// and `runInShell: true` stacked a second cmd.exe on top of the first.
///
/// Nobody had established whether the pipeline can actually deliver such a
/// URL. `launchUrl(..., LaunchMode.externalApplication)` hands ShellExecute
/// one opaque argument and there is no shell to parse it, which retires the
/// question instead of answering it. This test keeps it retired.
///
/// It reads the source because the branch is behind `Platform.isWindows` and
/// ends in a plugin channel: there is no seam a host test can drive.
void main() {
  test('no external-player launch path goes through a shell', () {
    final file = File('lib/core/services/external_player_service.dart');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'run this from the package root',
    );

    // Comments are allowed to name the old call - that is how the next reader
    // learns why it went - so only executable lines are scanned.
    final code = file
        .readAsLinesSync()
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');

    expect(
      code,
      isNot(contains('runInShell')),
      reason:
          'runInShell wraps the argument list in cmd.exe (or /bin/sh), which '
          're-parses a plugin-supplied URL as a command line',
    );
    expect(
      code,
      isNot(contains("'cmd'")),
      reason: 'spawning cmd.exe means the URL is parsed by a shell',
    );
    expect(
      code,
      isNot(contains('/bin/sh')),
      reason: 'same hazard on the POSIX side',
    );

    // Every Process argument the URL travels in must be the whole argument,
    // never a fragment glued into a longer quoted string.
    final quotedInterpolation = RegExp(r'''["']\s*"\$''');
    expect(
      quotedInterpolation.hasMatch(code),
      isFalse,
      reason:
          'an argument built as \'"\$url"\' is quoting for a shell, so a shell '
          'is being relied on to take the quotes off again',
    );

    expect(
      code,
      contains('LaunchMode.externalApplication'),
      reason: 'the shell-free replacement for the default-handler fallback',
    );
  });
}
