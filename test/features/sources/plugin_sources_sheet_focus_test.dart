import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/network/link_probe_service.dart';
import 'package:skystream/core/nuvio/data/nuvio_stream_service.dart';
import 'package:skystream/core/nuvio/models/nuvio_models.dart';
import 'package:skystream/features/sources/presentation/plugin_sources_sheet.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// The sheet's TV model, asserted against the real widget rather than a
/// stand-in: UP/DOWN steps between source cards, LEFT/RIGHT moves inside the
/// focused card, and a probe landing under the user never moves the row they
/// are standing on.
void main() {
  testWidgets('DOWN steps card to card, never onto an action button', (
    tester,
  ) async {
    await _pumpSheet(tester);

    expect(_focusedRect(), _cardRect(tester, 'alpha'));

    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focusedRect(), _cardRect(tester, 'beta'));

    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focusedRect(), _cardRect(tester, 'gamma'));
  });

  testWidgets('UP steps card to card, never onto an action button', (
    tester,
  ) async {
    await _pumpSheet(tester);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focusedRect(), _cardRect(tester, 'gamma'));

    _forgetTraversalHistory(tester);
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focusedRect(), _cardRect(tester, 'beta'));

    _forgetTraversalHistory(tester);
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focusedRect(), _cardRect(tester, 'alpha'));
  });

  testWidgets('LEFT and RIGHT walk the focused card\'s own buttons', (
    tester,
  ) async {
    await _pumpSheet(tester);
    await _press(tester, LogicalKeyboardKey.arrowDown);

    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focusedRect(), _chipRect(tester, 'beta', 'Play'));

    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focusedRect(), _chipRect(tester, 'beta', 'Download now'));

    await _press(tester, LogicalKeyboardKey.arrowLeft);
    expect(_focusedRect(), _chipRect(tester, 'beta', 'Play'));

    await _press(tester, LogicalKeyboardKey.arrowLeft);
    expect(_focusedRect(), _cardRect(tester, 'beta'));
  });

  testWidgets('RIGHT on Download stays put instead of bouncing to Play', (
    tester,
  ) async {
    // Download is the last chip, so its RIGHT goes unhandled and bubbles up to
    // the card, whose own handler hops to Play. Without the primary-focus
    // guard the user is thrown backwards every time they overshoot.
    await _pumpSheet(tester);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focusedRect(), _chipRect(tester, 'beta', 'Download now'));

    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focusedRect(), _chipRect(tester, 'beta', 'Download now'));
  });

  testWidgets('DOWN from an action button lands on the next card', (
    tester,
  ) async {
    await _pumpSheet(tester);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    await _press(tester, LogicalKeyboardKey.arrowRight);

    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focusedRect(), _cardRect(tester, 'gamma'));
  });

  testWidgets('the focused card paints a ring the neighbours do not', (
    tester,
  ) async {
    await _pumpSheet(tester);
    await _press(tester, LogicalKeyboardKey.arrowDown);

    expect(_cardBorder(tester, 'beta').width, 2);
    expect(_cardBorder(tester, 'alpha').width, 1.2);
    expect(_cardBorder(tester, 'gamma').width, 1.2);
    expect(_cardBorder(tester, 'beta').color, isNot(_cardBorder(tester, 'alpha').color));
  });

  testWidgets('a probe that fails under the user leaves the row in place', (
    tester,
  ) async {
    final probe = _FakeProbeService(autoReachable: false);
    await _pumpSheet(tester, probeService: probe);

    await _press(tester, LogicalKeyboardKey.arrowDown);
    final Rect standingOn = _cardRect(tester, 'beta');

    probe.complete('https://cdn.test/beta.mkv', reachable: false);
    await _flush(tester);

    // Still mounted, still where it was, still holding focus.
    expect(_nameFinder('beta'), findsOneWidget);
    expect(_cardRect(tester, 'beta'), standingOn);
    expect(_focusedRect(), standingOn);

    // Stepping off releases it into the collapsed unavailable section.
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_nameFinder('beta'), findsNothing);
    expect(find.text('1 unavailable'), findsOneWidget);
  });

  testWidgets('light theme does not paint white-on-white', (tester) async {
    await _pumpSheet(tester, brightness: Brightness.light);

    final Text name = tester.widget<Text>(_nameFinder('alpha'));
    expect(name.style!.color, isNot(Colors.white));

    // The focus ring has to stay legible against a light card too.
    expect(_cardBorder(tester, 'alpha').color, isNot(Colors.white));
  });

  testWidgets('a row keeps its focus when the list reorders around it', (
    tester,
  ) async {
    final probe = _FakeProbeService(autoReachable: false);
    await _pumpSheet(tester, probeService: probe);

    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focusedRect(), _cardRect(tester, 'beta'));

    // alpha drops out, so beta is promoted from the third list slot to the
    // second. Keyed rows keep their State, and with it their focus.
    probe.complete('https://cdn.test/alpha.mkv', reachable: false);
    await _flush(tester);

    expect(_nameFinder('alpha'), findsNothing);
    expect(_focusedRect(), _cardRect(tester, 'beta'));
  });
}

Rect? _focusedRect() => FocusManager.instance.primaryFocus?.rect;

/// Flutter's directional policy retraces its own history when the direction
/// reverses, so a DOWN used to reach the bottom card would answer the next UP
/// from that record rather than from geometry — and geometry is the thing
/// under test.
void _forgetTraversalHistory(WidgetTester tester) {
  final FocusNode focused = FocusManager.instance.primaryFocus!;
  FocusTraversalGroup.of(
    focused.context!,
  ).invalidateScopeData(focused.nearestScope!);
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await _flush(tester);
}

/// A probe left deliberately pending keeps [ProbeBadge]'s spinner running, so
/// the sheet never reaches a settled frame; pump a bounded number instead.
Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

/// Provider names also label the filter-chip rail, so every lookup is scoped
/// to the vertical source list.
final Finder _sourceList = find.byWidgetPredicate(
  (widget) => widget is ListView && widget.scrollDirection == Axis.vertical,
);

Finder _nameFinder(String provider) =>
    find.descendant(of: _sourceList, matching: find.text(provider));

/// The card is the [AnimatedContainer] above a provider's name.
Finder _cardFinder(String provider) => find
    .ancestor(
      of: _nameFinder(provider),
      matching: find.byType(AnimatedContainer),
    )
    .last;

Rect _cardRect(WidgetTester tester, String provider) =>
    tester.getRect(_cardFinder(provider));

BorderSide _cardBorder(WidgetTester tester, String provider) {
  final container = tester.widget<AnimatedContainer>(_cardFinder(provider));
  return ((container.decoration! as BoxDecoration).border! as Border).top;
}

Rect _chipRect(WidgetTester tester, String provider, String label) =>
    tester.getRect(
      find
          .descendant(
            of: _cardFinder(provider),
            matching: find.ancestor(
              of: find.text(label),
              matching: find.byType(AnimatedContainer),
            ),
          )
          .first,
    );

Future<void> _pumpSheet(
  WidgetTester tester, {
  _FakeProbeService? probeService,
  Brightness brightness = Brightness.dark,
}) async {
  final streams = [
    _stream('alpha', 'https://cdn.test/alpha.mkv'),
    _stream('beta', 'https://cdn.test/beta.mkv'),
    _stream('gamma', 'https://cdn.test/gamma.mkv'),
  ];

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        nuvioStreamServiceProvider.overrideWithValue(
          _FakeNuvioService(streams),
        ),
        linkProbeServiceProvider.overrideWithValue(
          probeService ?? _FakeProbeService(),
        ),
      ],
      child: MaterialApp(
        // The sheet reads AppLocalizations from its first frame - the empty
        // state it paints before any scraper answers is one of seven
        // different sentences now, not one hardcoded string.
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(brightness: brightness),
        home: PluginSourcesSheet(target: _target),
      ),
    ),
  );
  await _flush(tester);
}

NuvioStreamResult _stream(String name, String url) => NuvioStreamResult(
  scraperId: name,
  scraperName: name,
  title: 'Movie ${name.toUpperCase()}',
  url: url,
  quality: '1080p',
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
    yield NuvioProgress(
      streams: streams,
      completedCount: 1,
      totalCount: 1,
    );
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Hands out a pending probe per URL so a test can decide exactly when a
/// result lands — which is the moment the sheet re-buckets a row.
class _FakeProbeService implements LinkProbeService {
  _FakeProbeService({this.autoReachable = true});

  final bool autoReachable;
  final Map<String, Completer<LinkProbeResult>> _pending = {};

  void complete(String url, {required bool reachable}) {
    _pending[url]?.complete(
      LinkProbeResult(
        reachable: reachable,
        failureReason: reachable ? null : 'Not found (404)',
      ),
    );
  }

  @override
  Future<LinkProbeResult> probe(String url, {Map<String, String>? headers}) {
    if (autoReachable) {
      return Future.value(const LinkProbeResult(reachable: true));
    }
    return (_pending[url] ??= Completer<LinkProbeResult>()).future;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
