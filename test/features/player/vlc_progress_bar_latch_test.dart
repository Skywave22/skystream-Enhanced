import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_progress_bar.dart';
import 'package:skystream/features/player/presentation/widgets/player_stream_widgets.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart';

import 'fake_vlc_engine.dart';

/// The seek latch: after a seek the thumb and the clock stay on the target
/// until the engine has evidently honoured it.
///
/// The controller publishes only the engine's own position - a faked one
/// would poison the resume-point writer - so on finger-up the bar used to
/// repaint at the stale pre-seek position for a snapshot round-trip, and a
/// D-pad press landing in that window started from the stale value and undid
/// the burst before it. The bar now holds the target itself, and releases it
/// on the engine's word, on the media stopping, or on a timeout that is
/// deliberately longer than the controller's stall delay so a slow seek shows
/// its spinner over a thumb that is still where the viewer put it.
///
/// The controller is attached with the screen's 250 ms throttle, so progress
/// ticks land only on a flush; tests pump past it after every tick.
const Duration _throttle = Duration(milliseconds: 250);
const int _hour = 3600000;

/// PlayerScrubber's D-pad step, in ms: the viewer's configured seek duration,
/// whose default is 10 s. Every test here runs on the default; the one that is
/// about the setting overrides it.
const int _step = 10000;

/// The label the scrubber prints for [ms], matching its own formatter.
String _clock(int ms) {
  final d = Duration(milliseconds: ms);
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// Every seekTo the engine received, as the millisecond it was asked for.
List<int> _seeks(FakeVlcEngine engine) => engine
    .callsTo('seekTo')
    .map((call) => (call.arguments as Map)['position'] as int)
    .toList(growable: false);

void main() {
  late FakeVlcEngine engine;
  late VlcPlayerController controller;
  late FocusNode barFocus;

  /// Where the bar publishes the position it is showing, for the clock below
  /// it. The controls own one of these; this stands in for that.
  late ValueNotifier<Duration> clockPosition;

  setUp(() {
    engine = FakeVlcEngine();
    engine.install();
    barFocus = FocusNode(debugLabel: 'bar');
    clockPosition = ValueNotifier<Duration>(Duration.zero);
  });

  /// In the body, not a tearDown: a playing controller holds a 1 s stall
  /// timer and flutter_test checks pending timers before `addTearDown` runs.
  /// Unmount first so nothing listens to a dead notifier.
  Future<void> tearDownInBody(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    engine.dispose();
    barFocus.dispose();
    clockPosition.dispose();
  }

  /// Attached in the test body, never in `setUp`: a stream delivers in the
  /// zone it was listened from, and the controller's throttle timer is created
  /// from that delivery. Listened outside the test's FakeAsync zone it would be
  /// a real timer that no `tester.pump` ever fires.
  Future<void> pumpBar(
    WidgetTester tester, {
    VlcPlayerController? using,
    PlayerSettings settings = const PlayerSettings(),
  }) async {
    controller = using ?? await engine.attach(eventThrottleInterval: _throttle);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerSettingsProvider.overrideWithBuild((_, _) => settings),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: SizedBox(
                width: 800,
                // The clock is the visible evidence of the latch, and it is
                // not a child of the bar any more - it sits in the transport
                // row and reads the position the bar publishes. Pumped here
                // the way `VlcPlayerControls` pumps it, so these tests still
                // watch the latch through the read-out a viewer watches it
                // through.
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    VlcProgressBar(
                      controller: controller,
                      focusNode: barFocus,
                      displayPosition: clockPosition,
                    ),
                    ValueListenableBuilder<VlcPlayerValue>(
                      valueListenable: controller,
                      builder: (context, value, _) =>
                          ValueListenableBuilder<Duration>(
                            valueListenable: clockPosition,
                            builder: (context, position, _) => PlayerTimeLabel(
                              position: position,
                              duration: value.duration,
                              hasDuration: value.duration > Duration.zero,
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

  /// A bar on an hour-long, seekable film at [position]. The first snapshot
  /// changes the state, so it bypasses the throttle and lands at once.
  Future<void> start(
    WidgetTester tester, {
    int position = 2000,
    PlayerSettings settings = const PlayerSettings(),
  }) async {
    await pumpBar(tester, settings: settings);
    await engine.emit({'duration': _hour, 'position': position});
    await tester.pump();
    expect(find.text('${_clock(position)} / 1:00:00'), findsOneWidget);
  }

  /// One progress tick from the engine, flushed through the throttle.
  Future<void> tick(
    WidgetTester tester,
    int position, {
    int duration = _hour,
    String state = 'playing',
  }) async {
    await engine.emit({
      'duration': duration,
      'position': position,
      'state': state,
    });
    await tester.pump(_throttle + const Duration(milliseconds: 50));
    await tester.pump();
  }

  /// One D-pad press on the focused bar.
  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
  }

  /// Lets the seek bar's 500 ms burst timer commit the presses as one seek.
  Future<void> commit(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
  }

  Future<void> focusBar(WidgetTester tester) async {
    barFocus.requestFocus();
    await tester.pump();
    expect(barFocus.hasPrimaryFocus, isTrue);
  }

  final seekBar = find.byType(PlayerSeekBar);

  int shown(WidgetTester tester) => tester
      .widget<PlayerScrubber>(find.byType(PlayerScrubber))
      .position
      .inMilliseconds;

  void expectShown(WidgetTester tester, int ms, {String? reason}) {
    expect(shown(tester), ms, reason: reason);
    expect(
      find.text('${_clock(ms)} / 1:00:00'),
      findsOneWidget,
      reason: reason,
    );
  }

  testWidgets('a drag release holds the target until the engine reports it', (
    tester,
  ) async {
    await start(tester);

    await tester.drag(seekBar, const Offset(120, 0));
    await tester.pump();

    final seeks = _seeks(engine);
    expect(seeks, hasLength(1));
    final target = seeks.single;
    expect(target, greaterThan(2000));
    expectShown(
      tester,
      target,
      reason: 'the thumb stays where the finger left',
    );

    // The engine's read-back has not caught up: a tick continuing from where
    // playback was must not pull the thumb back.
    await tick(tester, 2250);
    expect(controller.value.position.inMilliseconds, 2250);
    expectShown(tester, target, reason: 'a stale tick keeps the latch');

    // It lands near the target - seeks land on a keyframe, not the exact ms.
    await tick(tester, target + 500);
    expectShown(tester, target + 500, reason: 'the engine is the truth again');

    await tearDownInBody(tester);
  });

  testWidgets('a tap on the track latches the same way', (tester) async {
    await start(tester);

    await tester.tapAt(tester.getCenter(seekBar) + const Offset(100, 0));
    await tester.pump();

    final seeks = _seeks(engine);
    expect(seeks, hasLength(1));
    final target = seeks.single;
    expectShown(tester, target);

    await tick(tester, 2250);
    expectShown(tester, target);

    await tick(tester, target - 300);
    expectShown(tester, target - 300);

    await tearDownInBody(tester);
  });

  testWidgets('moving past the target releases even outside the tolerance', (
    tester,
  ) async {
    await start(tester);
    await focusBar(tester);

    await press(tester, LogicalKeyboardKey.arrowRight);
    await commit(tester);
    expect(_seeks(engine), [2000 + _step]);
    expectShown(tester, 2000 + _step);

    await tick(tester, 2250);
    expectShown(tester, 2000 + _step, reason: 'not there yet');

    // The engine landed on a keyframe past the target and is playing on from
    // it: that is the seek honoured, and its position is the one to show.
    await tick(tester, 2000 + _step + 1500);
    expectShown(tester, 2000 + _step + 1500);

    await tearDownInBody(tester);
  });

  // Every other seek path - the keyboard's J/L, the double-tap, the swipe -
  // honours the viewer's seek duration; the bar hard-coded 30 s. On a
  // television the bar *is* the seek surface, so the setting was inert
  // exactly where it is felt.
  testWidgets('the D-pad step follows the seek-duration setting', (
    tester,
  ) async {
    await start(tester, settings: const PlayerSettings(seekDuration: 45));
    await focusBar(tester);

    await press(tester, LogicalKeyboardKey.arrowRight);
    await commit(tester);

    expect(_seeks(engine), [2000 + 45000]);
    expectShown(tester, 2000 + 45000);

    await tearDownInBody(tester);
  });

  // Nought is not a step. The controls' own `_seekStep` falls back to 10 s on
  // a stored zero and the bar has to agree, or the two disagree about what
  // one press means.
  testWidgets('a zero setting falls back to ten seconds, as J and L do', (
    tester,
  ) async {
    await start(tester, settings: const PlayerSettings(seekDuration: 0));
    await focusBar(tester);

    await press(tester, LogicalKeyboardKey.arrowRight);
    await commit(tester);

    expect(_seeks(engine), [2000 + 10000]);

    await tearDownInBody(tester);
  });

  testWidgets('a backward seek releases on the first tick below the target', (
    tester,
  ) async {
    await start(tester, position: 60000);
    await focusBar(tester);

    await press(tester, LogicalKeyboardKey.arrowLeft);
    await commit(tester);
    expect(_seeks(engine), [60000 - _step]);
    expectShown(tester, 60000 - _step);

    // Playback continuing forward from the origin is the stale read-back,
    // not the seek: it is the one direction a backward seek cannot produce.
    await tick(tester, 60250);
    expectShown(tester, 60000 - _step, reason: 'moved the wrong way');

    // Below the target by more than the tolerance is still past it.
    await tick(tester, 60000 - _step - 1000);
    expectShown(tester, 60000 - _step - 1000);

    await tearDownInBody(tester);
  });

  testWidgets(
    'a seek the engine never answers shows the stall first, then the truth',
    (tester) async {
      await start(tester);
      await focusBar(tester);

      await press(tester, LogicalKeyboardKey.arrowRight);
      await commit(tester);
      const target = 2000 + _step;
      expect(_seeks(engine), [target]);
      expect(controller.value.isStalled, isFalse);

      // The controller's stall delay elapses first: the spinner is owed with
      // the thumb still on the target, so the viewer sees "seeking, stuck"
      // rather than "the seek was ignored".
      await tester.pump(controller.stallIndicatorDelay);
      expect(controller.value.isStalled, isTrue);
      expectShown(tester, target, reason: 'the latch outlives the stall delay');

      // Then the latch gives up on its own and the published position is
      // what the bar shows; the next press will count from that truth.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expectShown(tester, 2000, reason: 'timed out to the engine');
      expect(controller.value.isStalled, isTrue);

      await tearDownInBody(tester);
    },
  );

  testWidgets('the media ending releases the latch at once', (tester) async {
    await start(tester);
    await focusBar(tester);

    await press(tester, LogicalKeyboardKey.arrowRight);
    await commit(tester);
    expectShown(tester, 2000 + _step);

    // A state change bypasses the throttle, so no flush is needed.
    await engine.emit({'duration': _hour, 'position': 2000, 'state': 'ended'});
    await tester.pump();
    expect(controller.value.state, VlcPlaybackState.ended);
    expectShown(tester, 2000);

    await tearDownInBody(tester);
  });

  testWidgets('a paused engine keeps the latch', (tester) async {
    await start(tester);
    await focusBar(tester);

    await press(tester, LogicalKeyboardKey.arrowRight);
    await commit(tester);

    // Paused at the old position: the seek is still on its way.
    await engine.emit({'duration': _hour, 'position': 2000, 'state': 'paused'});
    await tester.pump();
    expectShown(tester, 2000 + _step);

    // Paused at the target: it landed.
    await engine.emit({
      'duration': _hour,
      'position': 2000 + _step,
      'state': 'paused',
    });
    await tester.pump(_throttle + const Duration(milliseconds: 50));
    await tester.pump();
    expectShown(tester, 2000 + _step);
    expect(controller.value.position.inMilliseconds, 2000 + _step);

    await tearDownInBody(tester);
  });

  testWidgets('TV: a second burst before the engine answers chains from the '
      'first target', (tester) async {
    await start(tester);
    await focusBar(tester);

    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await commit(tester);

    const first = 2000 + 3 * _step;
    expect(_seeks(engine), [first], reason: 'one burst, one seek');
    expectShown(tester, first);

    // No snapshot arrives. The next press must count from the target the
    // viewer can see, not from the position the engine last published.
    await press(tester, LogicalKeyboardKey.arrowRight);
    await commit(tester);

    expect(_seeks(engine), [first, first + _step]);
    expectShown(tester, first + _step);

    await tearDownInBody(tester);
  });

  testWidgets('the duration going back to zero clears the latch', (
    tester,
  ) async {
    await start(tester);
    await focusBar(tester);

    await press(tester, LogicalKeyboardKey.arrowRight);
    await commit(tester);
    expectShown(tester, 2000 + _step);

    // New media under the same controller: no length yet, so no target to
    // hold on to and no scale to hold it on.
    await tick(tester, 2250, duration: 0);
    expect(shown(tester), 2250);
    expect(find.text('0:02 / --:--'), findsOneWidget);

    await tearDownInBody(tester);
  });

  testWidgets('a new controller clears the latch and stops following the old', (
    tester,
  ) async {
    await start(tester);
    await focusBar(tester);

    await press(tester, LogicalKeyboardKey.arrowRight);
    await commit(tester);
    expectShown(tester, 2000 + _step);

    final original = controller;
    final second = FakeVlcEngine(viewId: 2);
    second.install();
    final replacement = await second.attach(eventThrottleInterval: _throttle);
    await pumpBar(tester, using: replacement);
    await tester.pump();

    expect(shown(tester), 0, reason: 'the new controller has not played');

    // The old controller ticking on must not reach the bar any more.
    await engine.emit({'duration': _hour, 'position': 2000 + _step});
    await tester.pump(_throttle + const Duration(milliseconds: 50));
    await tester.pump();
    expect(shown(tester), 0);

    await second.emit({'duration': _hour, 'position': 5000});
    await tester.pump();
    expect(shown(tester), 5000);

    await tester.pumpWidget(const SizedBox());
    original.dispose();
    replacement.dispose();
    second.dispose();
    engine.dispose();
    barFocus.dispose();
  });
}
