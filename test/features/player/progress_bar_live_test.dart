import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_progress_bar.dart';
import 'package:skystream/features/player/presentation/widgets/player_stream_widgets.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart';

import 'fake_vlc_engine.dart';

/// LIVE is a verdict, not a missing length.
///
/// The clock is no longer a child of the bar - it moved into the transport row
/// on every form factor - so [pumpBar] renders the two halves the way
/// `VlcPlayerControls` does: the bar publishes the position it is showing into
/// a notifier, and a [PlayerTimeLabel] beside it reads that. Which means these
/// tests also cover the seam between them, and a clock wired to the engine's
/// own position instead of the bar's would fail here.
///
/// libVLC reports the duration a beat after it starts playing, and for a few
/// hundred milliseconds every VOD item has `duration == 0`. The bar used to
/// read that as live and flash the red pill over a fully painted track - the
/// 1 ms scale clamped any position onto 100% - before snapping to a clock.
/// Now the pill is shown only when the app or the engine has actually said
/// live; an unknown length keeps the scrubber and reads `--:--`.
void main() {
  late FakeVlcEngine engine;
  late VlcPlayerController controller;

  setUp(() async {
    engine = FakeVlcEngine();
    engine.install();
    controller = await engine.attach();
  });

  /// The controller is disposed in the body of every test: a playing one holds
  /// a 1 s stall timer, and flutter_test checks pending timers before
  /// `addTearDown` runs. Unmount first so nothing listens to a dead notifier.
  Future<void> tearDownInBody(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    engine.dispose();
  }

  Future<AppLocalizations> l10nFor(String locale) =>
      AppLocalizations.delegate.load(Locale(locale));

  late ValueNotifier<Duration> clockPosition;

  Future<void> pumpBar(
    WidgetTester tester, {
    bool isLive = false,
    bool showRemaining = false,
    Locale? locale,
  }) {
    clockPosition = ValueNotifier<Duration>(controller.value.position);
    return tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerSettingsProvider.overrideWithBuild(
            (_, _) => PlayerSettings(showRemainingTime: showRemaining),
          ),
        ],
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: SizedBox(
                width: 800,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    VlcProgressBar(
                      controller: controller,
                      isLive: isLive,
                      displayPosition: clockPosition,
                    ),
                    // The transport row's clock, built the way
                    // `VlcPlayerControls._clock` builds it.
                    ValueListenableBuilder<VlcPlayerValue>(
                      valueListenable: controller,
                      builder: (context, value, _) =>
                          ValueListenableBuilder<Duration>(
                            valueListenable: clockPosition,
                            builder: (context, position, _) => PlayerTimeLabel(
                              position: position,
                              duration: value.duration,
                              hasDuration: value.duration > Duration.zero,
                              isLive: isLive || value.isLive,
                            ),
                          ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// One snapshot from the fake, landed on the next frame (no throttle).
  Future<void> emit(WidgetTester tester, Map<String, Object?> partial) async {
    await engine.emit(partial);
    await tester.pump();
  }

  final seekBar = find.byType(PlayerSeekBar);

  /// The bar's own Focus - the one that decides whether D-pad traversal can
  /// land here at all.
  Focus barFocus(WidgetTester tester) => tester.widget<Focus>(
    find.descendant(of: seekBar, matching: find.byType(Focus)).first,
  );

  /// The thumb is the only FractionalTranslation in an unhovered bar; the
  /// hover line and tooltip only exist under a pointer.
  final thumb = find.descendant(
    of: seekBar,
    matching: find.byType(FractionalTranslation),
  );

  /// Both the played and the buffered band paint through a ClipRRect and are
  /// dropped entirely (`SizedBox.shrink`) at zero width, so none present means
  /// nothing is filled.
  final fill = find.descendant(of: seekBar, matching: find.byType(ClipRRect));

  testWidgets(
    'seekable media with no length yet keeps a scrubber that reads --:--',
    (tester) async {
      final l10n = await l10nFor('en');
      await pumpBar(tester);
      await emit(tester, {'isSeekable': true, 'duration': 0, 'isLive': false});

      expect(find.text(l10n.live), findsNothing);
      expect(find.text('0:01 / --:--'), findsOneWidget);
      expect(fill, findsNothing, reason: '1 ms scale used to paint 100%');
      expect(thumb, findsNothing, reason: 'no scale to place a thumb on');
      expect(barFocus(tester).canRequestFocus, isFalse);
      expect(barFocus(tester).skipTraversal, isTrue);

      await tearDownInBody(tester);
    },
  );

  testWidgets('the clock and the thumb arrive with the length', (tester) async {
    final l10n = await l10nFor('en');
    await pumpBar(tester);
    await emit(tester, {'duration': 0});
    expect(find.text('0:01 / --:--'), findsOneWidget);

    await emit(tester, {'duration': 5400000});

    expect(find.text('0:01 / 1:30:00'), findsOneWidget);
    expect(find.text(l10n.live), findsNothing);
    expect(thumb, findsOneWidget);
    expect(fill, findsOneWidget, reason: 'the played band is painted');
    expect(barFocus(tester).canRequestFocus, isTrue);
    expect(barFocus(tester).skipTraversal, isFalse);

    await tearDownInBody(tester);
  });

  testWidgets('remaining-time mode has nothing to count down from', (
    tester,
  ) async {
    await pumpBar(tester, showRemaining: true);
    await emit(tester, {'duration': 0});

    expect(find.text('0:01 / --:--'), findsOneWidget);
    expect(find.textContaining('-0:00'), findsNothing);

    await emit(tester, {'duration': 5400000});
    expect(find.text('-1:29:58 / 1:30:00'), findsOneWidget);

    await tearDownInBody(tester);
  });

  testWidgets('the engine calling it live shows the pill and locks the bar', (
    tester,
  ) async {
    final l10n = await l10nFor('en');
    await pumpBar(tester);
    await emit(tester, {'isSeekable': false, 'duration': 0, 'isLive': true});

    expect(find.text(l10n.live), findsOneWidget);
    expect(find.textContaining('/'), findsNothing);
    expect(thumb, findsNothing);
    expect(barFocus(tester).canRequestFocus, isFalse);

    await tearDownInBody(tester);
  });

  testWidgets(
    'the app calling it live wins over a seekable DVR window with a length',
    (tester) async {
      final l10n = await l10nFor('en');
      await pumpBar(tester, isLive: true);
      await emit(tester, {
        'isSeekable': true,
        'duration': 3 * 60 * 60 * 1000,
        'isLive': false,
      });

      expect(find.text(l10n.live), findsOneWidget);
      expect(find.textContaining('3:00:00'), findsNothing);
      expect(thumb, findsNothing, reason: 'canSeek is false on a live verdict');
      expect(barFocus(tester).canRequestFocus, isFalse);

      await tearDownInBody(tester);
    },
  );

  testWidgets('the pill is localised', (tester) async {
    final en = await l10nFor('en');
    final hi = await l10nFor('hi');
    expect(hi.live, isNot(en.live), reason: 'hi has its own translation');

    await pumpBar(tester, isLive: true);
    await emit(tester, {'state': 'paused'});
    expect(find.text(en.live), findsOneWidget);

    await pumpBar(tester, isLive: true, locale: const Locale('hi'));
    await tester.pump();
    expect(find.text(hi.live), findsOneWidget);
    expect(find.text(en.live), findsNothing);

    await tearDownInBody(tester);
  });
}
