import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/network/link_probe_service.dart';
import 'package:skystream/core/nuvio/data/nuvio_stream_service.dart';
import 'package:skystream/core/nuvio/models/nuvio_models.dart';
import 'package:skystream/features/details/presentation/playback_launcher.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/features/sources/presentation/plugin_sources_sheet.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// This sheet sits behind the TMDB details screen's primary Play affordance
/// and behind every episode row, and it used to push the built-in player
/// itself. "Default Player" lives one layer up, in [PlaybackLauncher], so a
/// user who had chosen MX Player got the built-in one here with no notice.
void main() {
  testWidgets('Play hands the picked source to the launcher', (tester) async {
    final _RecordingLauncher launcher = await _pumpSheet(tester);

    await tester.tap(_playChip('beta'));
    await _flush(tester);

    expect(
      launcher.calls,
      hasLength(1),
      reason: 'the sheet must not decide which player opens the source',
    );
    final _Call call = launcher.calls.single;
    expect(call.item.tmdbId, 1234);
    // No item URL on a TMDB title, so the player resolves against the id.
    expect(call.videoUrl, 'tmdb:1234');
    // Tapped row first, the rest kept behind it as failover candidates.
    expect(call.streams.map((StreamResult s) => s.url), <String>[
      'https://cdn.test/beta.mkv',
      'https://cdn.test/alpha.mkv',
      'https://cdn.test/gamma.mkv',
    ]);
  });

  testWidgets('the scraper headers travel with the picked source', (
    tester,
  ) async {
    // Whether they can be forwarded is the launcher's call to make; it can
    // only make it if they arrive.
    final _RecordingLauncher launcher = await _pumpSheet(tester);

    await tester.tap(_playChip('alpha'));
    await _flush(tester);

    expect(launcher.calls.single.streams.first.headers, <String, String>{
      'Referer': 'https://alpha.test/',
    });
  });
}

class _Call {
  _Call(this.item, this.videoUrl, this.streams);

  final MultimediaItem item;
  final String videoUrl;
  final List<StreamResult> streams;
}

class _RecordingLauncher extends PlaybackLauncher {
  _RecordingLauncher(super.ref);

  final List<_Call> calls = <_Call>[];

  @override
  Future<void> playResolved(
    BuildContext context, {
    required MultimediaItem item,
    required String videoUrl,
    Episode? episode,
    List<StreamResult> streams = const <StreamResult>[],
  }) async {
    calls.add(_Call(item, videoUrl, streams));
  }
}

/// The Play chip inside a named provider's card.
Finder _playChip(String provider) => find.descendant(
  of: find
      .ancestor(
        of: find.descendant(
          of: find.byWidgetPredicate(
            (Widget widget) =>
                widget is ListView && widget.scrollDirection == Axis.vertical,
          ),
          matching: find.text(provider),
        ),
        matching: find.byType(AnimatedContainer),
      )
      .last,
  matching: find.text('Play'),
);

/// A probe left pending keeps a spinner running, so the sheet never settles;
/// pump a bounded number of frames instead.
Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<_RecordingLauncher> _pumpSheet(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final List<NuvioStreamResult> streams = <NuvioStreamResult>[
    _stream('alpha', 'https://cdn.test/alpha.mkv'),
    _stream('beta', 'https://cdn.test/beta.mkv'),
    _stream('gamma', 'https://cdn.test/gamma.mkv'),
  ];

  final ProviderContainer container = ProviderContainer(
    overrides: [
      nuvioStreamServiceProvider.overrideWithValue(_FakeNuvioService(streams)),
      linkProbeServiceProvider.overrideWithValue(_FakeProbeService()),
      playbackLauncherProvider.overrideWith(
        (Ref ref) => _RecordingLauncher(ref),
      ),
      // The sheet settles the settings box before it pops, so that a cold
      // start cannot resolve them after its context is gone.
      playerSettingsProvider.overrideWithBuild(
        (_, _) => const PlayerSettings(),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(brightness: Brightness.dark),
        home: PluginSourcesSheet(target: _target),
      ),
    ),
  );
  await _flush(tester);
  return container.read(playbackLauncherProvider) as _RecordingLauncher;
}

NuvioStreamResult _stream(String name, String url) => NuvioStreamResult(
  scraperId: name,
  scraperName: name,
  title: 'Movie ${name.toUpperCase()}',
  url: url,
  quality: '1080p',
  headers: <String, String>{'Referer': 'https://$name.test/'},
);

final MultimediaItem _target = MultimediaItem(
  title: 'Test Movie',
  url: '',
  posterUrl: '',
  tmdbId: 1234,
);

/// Emits a fixed result set without touching the scraper repository.
class _FakeNuvioService implements NuvioStreamService {
  _FakeNuvioService(this.streams);

  final List<NuvioStreamResult> streams;

  @override
  Stream<NuvioProgress> resolve({
    required String tmdbId,
    required String mediaType,
    int? season,
    int? episode,
  }) async* {
    yield NuvioProgress(streams: streams, completedCount: 1, totalCount: 1);
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeProbeService implements LinkProbeService {
  @override
  Future<LinkProbeResult> probe(String url, {Map<String, String>? headers}) =>
      Future<LinkProbeResult>.value(const LinkProbeResult(reachable: true));

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
