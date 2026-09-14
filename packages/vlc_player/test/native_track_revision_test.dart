import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `trackRevision` is a cross-platform contract (`lib/src/vlc_player_value.dart`)
/// that only the five native backends can honour, and none of them is
/// reachable from a Dart test: macOS/iOS are Swift over VLCKit, Android is
/// Kotlin over libvlc-android, Windows/Linux share the C++ core. What can be
/// pinned here is the shape of the derivation. The polling backends (macOS,
/// iOS, Windows, Linux) diff the track set rather than the track count, so a
/// same-size swap - an adaptive rendition change, or an MPEG-TS PMT update
/// replacing the audio/spu ES - still moves the revision. Android bumps only
/// for audio and subtitle streams, so a video-only ES change does not reload a
/// list that has not changed.
///
/// The C++ core additionally has a behavioural test in
/// `test/native/vlc_player_core_test_suite.h`
/// (`VlcPlayerCore.TrackSetFingerprintMovesOnASameSizeSwap`).
void main() {
  const darwinPlugins = <String, String>{
    'macOS': 'macos/vlc_player/Sources/vlc_player/VlcPlayerPlugin.swift',
    'iOS': 'ios/vlc_player/Sources/vlc_player/VlcPlayerPlugin.swift',
  };

  test('the C++ core diffs the track set rather than the track count', () {
    final snapshot = _blockAt(
      _fileText('src/native/vlc_player_core.cc'),
      'VlcSnapshot VlcPlayerCore::Snapshot()',
    );

    expect(
      snapshot,
      contains('TrackSetFingerprint(GetAudioTracks(), GetSubtitleTracks())'),
      reason:
          'Windows and Linux poll this; the revision has to move when the '
          'two lists are replaced, not only when they change length.',
    );
    expect(snapshot, contains('last_track_fingerprint_'));
    expect(snapshot, isNot(contains('audioTrackCount()')));
    expect(snapshot, isNot(contains('spuCount()')));
  });

  for (final entry in darwinPlugins.entries) {
    test('${entry.key} diffs the track set rather than the track count', () {
      final source = _fileText(entry.value);
      final sendSnapshot = _blockAt(source, 'private func sendSnapshot(');

      expect(
        sendSnapshot,
        contains('Self.trackFingerprint(mediaPlayer)'),
        reason:
            'VLCKit has no per-ES callback, so the snapshot itself has to '
            'notice a replaced track list.',
      );
      expect(sendSnapshot, contains('lastTrackFingerprint'));
      // A swap that keeps the size cannot be seen through either count.
      expect(sendSnapshot, isNot(contains('audioTrackIndexes.count')));
      expect(sendSnapshot, isNot(contains('videoSubTitlesIndexes.count')));
      expect(sendSnapshot, isNot(contains('lastTrackCount')));
    });

    test('${entry.key} fingerprints both ids and names of both lists', () {
      final source = _fileText(entry.value);
      final fingerprint = _blockAt(
        source,
        'private static func trackFingerprint(',
      );

      // Both published lists, so a subtitle-only change is seen too.
      expect(fingerprint, contains('mediaPlayer.audioTrackIndexes'));
      expect(fingerprint, contains('mediaPlayer.audioTrackNames'));
      expect(fingerprint, contains('mediaPlayer.videoSubTitlesIndexes'));
      expect(fingerprint, contains('mediaPlayer.videoSubTitlesNames'));
      // Ids identify the elementary stream; names are what the viewer reads,
      // and a rename with the ids intact is still a different list to draw.
      expect(fingerprint, contains('index.intValue'));
      expect(fingerprint, contains('trackNames[offset]'));
    });
  }

  test('Android bumps trackRevision only for audio and subtitle streams', () {
    final source = _fileText(
      'android/src/main/kotlin/com/lingjhf/vlc_player/VlcPlayerPlatformView.kt',
    );
    final branch = _blockAt(source, 'MediaPlayer.Event.ESAdded,');

    expect(
      branch,
      contains('trackRevision += 1'),
      reason:
          'An audio or subtitle ES appearing or vanishing is still the '
          'only signal Android has that the lists changed.',
    );

    final guard = _guardOf(branch, 'trackRevision += 1');
    expect(
      guard,
      isNotNull,
      reason:
          'An unguarded bump fires for the video ES too, which is what '
          'reloaded the panel on every adaptive rendition change.',
    );
    expect(
      _esTypesAcceptedBy(guard!),
      <String>{'Audio', 'Text'},
      reason:
          'Video and Unknown streams appear in neither published list, so '
          'they must not invalidate a consumer\'s cache.',
    );

    // sendSnapshot() still runs for every ES event: the active-track ids and
    // the rest of the payload are read fresh either way.
    expect(branch, contains('sendSnapshot()'));
  });
}

String _fileText(String path) => File(path).readAsStringSync();

/// The `{ ... }` block that follows [declaration], braces balanced.
String _blockAt(String source, String declaration) {
  final start = source.indexOf(declaration);
  if (start == -1) {
    fail('Could not find "$declaration".');
  }
  if (source.indexOf(declaration, start + declaration.length) != -1) {
    fail('"$declaration" is ambiguous: it appears more than once.');
  }
  final open = source.indexOf('{', start);
  if (open == -1) {
    fail('Could not find the body of "$declaration".');
  }

  var depth = 0;
  for (var index = open; index < source.length; index += 1) {
    final char = source.codeUnitAt(index);
    if (char == 0x7b) {
      depth += 1;
    } else if (char == 0x7d) {
      depth -= 1;
      if (depth == 0) {
        return source.substring(open, index + 1);
      }
    }
  }
  fail('Unbalanced braces in the body of "$declaration".');
}

/// The condition of the innermost `if (...)` [statement] sits inside, or null
/// when [statement] is not guarded at all.
String? _guardOf(String block, String statement) {
  final at = block.indexOf(statement);
  if (at == -1) {
    fail('Could not find "$statement".');
  }

  final before = block.substring(0, at);
  final open = before.lastIndexOf('{');
  if (open == -1) {
    return null;
  }
  final head = before.substring(0, open);
  final condition = head.lastIndexOf('if (');
  if (condition == -1 || head.substring(condition).contains('}')) {
    return null;
  }
  return head.substring(condition + 'if ('.length);
}

/// Which `IMedia.Track.Type` constants [guard] lets through.
Set<String> _esTypesAcceptedBy(String guard) {
  return <String>{
    for (final type in const <String>['Unknown', 'Audio', 'Video', 'Text'])
      if (guard.contains('IMedia.Track.Type.$type')) type,
  };
}
