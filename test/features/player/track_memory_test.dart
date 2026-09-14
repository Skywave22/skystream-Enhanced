import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/track_memory.dart';
import 'package:vlc_player/vlc_player.dart';

VlcTrackDescription _t(int id, {String? language, String name = ''}) =>
    VlcTrackDescription(id: id, name: name, language: language);

/// Carrying an audio or subtitle pick across a reopen.
///
/// The cost of getting this wrong is asymmetric, and the rules follow from
/// that: handing back the wrong track plays a film in a language the viewer
/// did not choose, while handing back nothing leaves the engine's own default,
/// which is exactly where they would have been anyway. So every rule here
/// prefers null to a guess.
void main() {
  group('a recovery of the same file', () {
    test('takes the id back when the language agrees', () {
      final tracks = <VlcTrackDescription>[
        _t(1, language: 'eng'),
        _t(3, language: 'fra'),
      ];

      final match = matchRememberedTrack(
        tracks,
        const RememberedTrack(id: 3, language: 'fra'),
      );

      expect(match?.id, 3);
    });
  });

  group('a failover to another provider', () {
    test('follows the language when the ids have been renumbered', () {
      // Same film, another release: the French track is id 7 here.
      final tracks = <VlcTrackDescription>[
        _t(5, language: 'eng'),
        _t(7, language: 'fra'),
      ];

      final match = matchRememberedTrack(
        tracks,
        const RememberedTrack(id: 3, language: 'fra'),
      );

      expect(match?.id, 7);
    });

    test('refuses an id that survived while the language did not', () {
      // The dangerous case, and the reason the id is not a fallback: id 3
      // exists in the new source and is a completely different language.
      final tracks = <VlcTrackDescription>[
        _t(1, language: 'eng'),
        _t(3, language: 'deu'),
      ];

      final match = matchRememberedTrack(
        tracks,
        const RememberedTrack(id: 3, language: 'fra'),
      );

      expect(
        match,
        isNull,
        reason: 'German is not French, however familiar the number looks',
      );
    });

    test('regional variants of one language still match', () {
      final tracks = <VlcTrackDescription>[_t(9, language: 'pt-BR')];

      final match = matchRememberedTrack(
        tracks,
        const RememberedTrack(id: 2, language: 'pt'),
      );

      expect(match?.id, 9);
    });
  });

  group('sources that declare no language', () {
    test('fall back to the label, which is all a scraped release has', () {
      final tracks = <VlcTrackDescription>[
        _t(1, name: 'AAC 2.0 English'),
        _t(2, name: 'AAC 5.1 Hindi'),
      ];

      final match = matchRememberedTrack(
        tracks,
        const RememberedTrack(id: 8, name: 'AAC 5.1 Hindi'),
      );

      expect(match?.id, 2);
    });

    test('fall back to the id only when there is nothing else to go on', () {
      final tracks = <VlcTrackDescription>[_t(1), _t(4)];

      final match = matchRememberedTrack(
        tracks,
        const RememberedTrack(id: 4),
      );

      expect(match?.id, 4);
    });
  });

  group('nothing to restore', () {
    test('no remembered pick matches nothing', () {
      expect(matchRememberedTrack(<VlcTrackDescription>[_t(1)], null), isNull);
    });

    test('an empty track list matches nothing', () {
      expect(
        matchRememberedTrack(
          const <VlcTrackDescription>[],
          const RememberedTrack(id: 1, language: 'eng'),
        ),
        isNull,
      );
    });

    test('"und" is not a language, so it matches no other unknown', () {
      final tracks = <VlcTrackDescription>[_t(2, language: 'und')];

      final match = matchRememberedTrack(
        tracks,
        const RememberedTrack(id: 9, language: 'und'),
      );

      expect(match, isNull);
    });
  });

  group('snapshotting a pick', () {
    test('keeps every signal the restore will need', () {
      final remembered = RememberedTrack.of(
        _t(3, language: 'fra', name: 'French'),
      );

      expect(remembered?.id, 3);
      expect(remembered?.language, 'fra');
      expect(remembered?.name, 'French');
    });

    test('nothing selected remembers nothing', () {
      expect(RememberedTrack.of(null), isNull);
    });
  });
}
