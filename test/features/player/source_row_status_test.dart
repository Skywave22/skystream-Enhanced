import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/player/domain/source_row_status.dart';
import 'package:skystream/features/player/domain/stream_resolver.dart';

/// Two facts about each source row, kept apart on purpose: what the
/// reachability check found, and what happened when the source was played.
///
/// They used to be merged into one status, with playing winning - so the row
/// being opened stopped saying it was reachable, and read as less proven than
/// the rows below it that had passed the same check.
void main() {
  const http = StreamResult(url: 'https://cdn.example/film.m3u8', source: 'A');

  group('reachability', () {
    SourceReachability reach(
      ProbeOutcome? probe, {
      StreamResult stream = http,
    }) => sourceReachabilityOf(stream, probe);

    test('a source nobody has checked is not checked', () {
      expect(reach(null), SourceReachability.notChecked);
    });

    test('is what the check found', () {
      expect(reach(ProbeOutcome.trying), SourceReachability.checking);
      expect(reach(ProbeOutcome.healthy), SourceReachability.reachable);
      expect(reach(ProbeOutcome.unhealthy), SourceReachability.unreachable);
    });

    // The check answers these without looking, so "reachable" would be a claim
    // nobody made: a magnet with no seeders passes it.
    test(
      'torrents and local files are not checked even when the check passed',
      () {
        for (final url in <String>[
          'magnet:?xt=urn:btih:abc',
          'https://tracker.example/pack.torrent',
          '/downloads/film.mkv',
        ]) {
          expect(
            reach(
              ProbeOutcome.healthy,
              stream: StreamResult(url: url, source: 'Torrent'),
            ),
            SourceReachability.notChecked,
            reason: url,
          );
        }
      },
    );
  });

  // Playing a source is stronger evidence than any request about it: a row
  // that has shown a picture reads reachable, whatever the probe said - or
  // could not say, for a torrent.
  group('reachability once a source has played', () {
    test('is reachable, even where the probe got no answer', () {
      expect(
        sourceReachabilityOf(http, ProbeOutcome.unhealthy, hasPlayed: true),
        SourceReachability.reachable,
      );
    });

    test('is reachable for a torrent the probe cannot look at', () {
      expect(
        sourceReachabilityOf(
          const StreamResult(url: 'magnet:?xt=urn:btih:abc', source: 'T'),
          null,
          hasPlayed: true,
        ),
        SourceReachability.reachable,
      );
    });
  });

  // "Unknown" is StreamResult's placeholder for a source whose plugin named no
  // provider - which every JS plugin's stream is. Printed, it put "Unknown ·"
  // in front of every row.
  group('the provider a row names', () {
    test('is none for the placeholder or a blank', () {
      expect(sourceProvider(const StreamResult(url: 'u', source: 's')), isNull);
      expect(
        sourceProvider(
          const StreamResult(url: 'u', source: 's', providerName: '  '),
        ),
        isNull,
      );
    });

    test('is the provider when one was named', () {
      expect(
        sourceProvider(
          const StreamResult(url: 'u', source: 's', providerName: 'Torrentio'),
        ),
        'Torrentio',
      );
    });
  });

  group('the row label', () {
    test('is the source alone when no provider was named', () {
      expect(
        sourceRowLabel(const StreamResult(url: 'u', source: 'HubCloud 1080p')),
        'HubCloud 1080p',
      );
    });

    test('leads with the provider when there is one', () {
      expect(
        sourceRowLabel(
          const StreamResult(
            url: 'u',
            source: '1080p',
            providerName: 'Torrentio',
          ),
        ),
        'Torrentio · 1080p',
      );
    });
  });

  group('play state', () {
    SourcePlayState play({
      bool isCurrent = false,
      bool hasPicture = false,
      bool failed = false,
    }) => sourcePlayStateOf(
      isCurrent: isCurrent,
      hasPicture: hasPicture,
      failed: failed,
    );

    test('a source nobody has opened is untried', () {
      expect(play(), SourcePlayState.untried);
    });

    test('the source being opened is opening until it has a picture', () {
      expect(play(isCurrent: true), SourcePlayState.opening);
      expect(play(isCurrent: true, hasPicture: true), SourcePlayState.playing);
    });

    test('a source that would not play has failed', () {
      expect(play(failed: true), SourcePlayState.failed);
    });

    // A viewer re-picking a source that failed earlier is trying it again.
    test('a failed source picked again is opening, not failed', () {
      expect(play(isCurrent: true, failed: true), SourcePlayState.opening);
    });
  });
}
