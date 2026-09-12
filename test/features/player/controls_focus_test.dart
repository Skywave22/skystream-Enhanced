import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/features/player/presentation/vlc/chrome_visibility_controller.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel.dart'
    show PlayerPanelTab;
import 'package:skystream/features/player/presentation/vlc/vlc_player_controls.dart';
import 'package:skystream/features/skip/data/skip_service.dart'
    show SkipSegment, SkipType;
import 'package:skystream/features/player/presentation/vlc/transient_overlay.dart'
    show PlayerSeekBurst, PlayerToast;
import 'package:skystream/features/player/presentation/widgets/player_control_components.dart'
    show PlayerActionButton, PlayerCenterPlayButton;
import 'package:skystream/features/player/presentation/widgets/player_stream_widgets.dart'
    show PlayerBufferingIndicator, PlayerSeekBar;
import 'package:skystream/features/player/presentation/player_platform_service.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart';

import 'fake_vlc_engine.dart';

/// On a television focus *is* the pointer. If it ever lands on the route's own
/// FocusScopeNode, every arrow is spent re-focusing that scope and the remote
/// is dead, with no tap to recover by. So the invariant this file holds is:
/// while the player is on screen, primary focus is either a chrome control or
/// the player's own key sink. Never the scope.
///
/// The desktop half holds the mouse contract: motion reveals, rest does not
/// re-arm, the bars never vanish under the cursor, and the cursor goes with
/// the chrome.
const Size _tv = Size(2560, 1440);
const Duration _hideAfter = Duration(seconds: 3);
const EventChannel _events = EventChannel('vlc_player/events/1');

/// Every list button the bar can show, so a test that is not about them sees
/// them all.
const Set<PlayerPanelTab> _allTabs = <PlayerPanelTab>{
  PlayerPanelTab.sources,
  PlayerPanelTab.audio,
  PlayerPanelTab.subtitles,
  PlayerPanelTab.episodes,
  PlayerPanelTab.files,
};

/// A panel that opens and closes at once. The default, so every list button
/// renders in tests that are about something else.
Future<void> _noPanel(PlayerPanelTab _) async {}

/// The hide timer refuses to fire until the engine reports playing, so every
/// test that waits for a hide starts by telling it so.
///
/// Position 0 on purpose: the controller only arms its stall watchdog once the
/// clock has moved, and a test ending in healthy playback with that timer
/// pending fails on flutter_test's pending-timer check.
Future<void> _play(WidgetTester tester) => _snapshot(tester);

/// One native snapshot, as the engine would send it. Sent on the fake's own
/// event channel, so it reaches the controller the fake attached.
Future<void> _snapshot(
  WidgetTester tester, {
  String state = 'playing',
  int position = 0,
  int duration = 30000,
  bool isSeekable = true,
}) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        _events.name,
        _events.codec.encodeSuccessEnvelope(<String, Object?>{
          'state': state,
          'position': position,
          'duration': duration,
          'volume': 100,
          'playbackSpeed': 1.0,
          'isReady': true,
          'isSeekable': isSeekable,
          'isLive': false,
        }),
        null,
      );
  await tester.pump();
}

/// Every seekTo the engine received, as the millisecond it was asked for.
List<int> _seeks(FakeVlcEngine engine) => engine
    .callsTo('seekTo')
    .map((call) => (call.arguments as Map)['position'] as int)
    .toList(growable: false);

/// Every setVolume the engine received, as the percentage it was asked for.
/// The fake never reports a volume back - its snapshot is a hardcoded 100 -
/// so what the widget asked for is the only truth here, which is exactly the
/// truth these tests are about.
List<int> _volumes(FakeVlcEngine engine) => engine
    .callsTo('setVolume')
    .map((call) => (call.arguments as Map)['volume'] as int)
    .toList(growable: false);

/// Every setPlaybackSpeed the engine received, as the rate it was asked for.
List<double> _speeds(FakeVlcEngine engine) => engine
    .callsTo('setPlaybackSpeed')
    .map((call) => (call.arguments as Map)['speed'] as double)
    .toList(growable: false);

/// A game controller's shoulder button, down and up.
///
/// flutter_test resolves a key code per platform and BUTTON_L1/R1 are in
/// Android's table - which is the platform that has the controllers, exactly
/// as for BUTTON_A below.
Future<void> _shoulder(WidgetTester tester, LogicalKeyboardKey key) async {
  final forward = key == LogicalKeyboardKey.gameButtonRight1;
  await tester.sendKeyEvent(
    key,
    platform: 'android',
    physicalKey: forward
        ? PhysicalKeyboardKey.gameButtonRight1
        : PhysicalKeyboardKey.gameButtonLeft1,
  );
  await tester.pump();
}

Widget _host(
  Widget child, {
  required bool isTv,
  PlayerSettings settings = const PlayerSettings(),
}) {
  return ProviderScope(
    overrides: [
      deviceProfileProvider.overrideWithValue(
        AsyncValue.data(DeviceProfile(isTv: isTv)),
      ),
      playerSettingsProvider.overrideWithBuild((_, _) => settings),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(fit: StackFit.expand, children: [child]),
      ),
    ),
  );
}

/// Desktop is whatever can toggle fullscreen; that is the file's own test.
///
/// [engine] is the fake the controller talks to; pass one to read its
/// `methods` back. [withoutPanel] stands in for `onOpenPanel: null`, which a
/// default parameter cannot express.
Future<VlcPlayerController> _pumpControls(
  WidgetTester tester, {
  bool isTv = true,
  bool desktop = false,
  Future<void> Function(PlayerPanelTab tab) onOpenPanel = _noPanel,
  bool withoutPanel = false,
  Set<PlayerPanelTab> panelTabs = _allTabs,
  VoidCallback? onNextEpisode,
  ChromeVisibilityController? chrome,
  FakeVlcEngine? engine,
  PlayerSettings settings = const PlayerSettings(),
  List<SkipSegment> skipSegments = const <SkipSegment>[],
}) async {
  tester.view.physicalSize = _tv;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final fake = engine ?? FakeVlcEngine();
  fake.install();
  // Tear-downs run last-in first-out: the controller goes first, while the
  // channel it sends `dispose` on still has a handler.
  addTearDown(fake.dispose);
  final controller = await fake.attach();
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    _host(
      VlcPlayerControls(
        controller: controller,
        chrome: chrome,
        title: 'The Body',
        subtitle: 'S5 E16',
        onBack: () {},
        onNextEpisode: onNextEpisode ?? () {},
        onOpenPanel: withoutPanel ? null : onOpenPanel,
        panelTabs: panelTabs,
        onToggleFullscreen: desktop ? () {} : null,
        skipSegments: skipSegments,
      ),
      isTv: isTv,
      settings: settings,
    ),
  );
  await tester.pump();
  await _play(tester);
  return controller;
}

FocusNode get _primary => FocusManager.instance.primaryFocus!;

/// Resolved through the focus tree, not `Focus.of`: the nodes that matter are
/// the ones the controls file owns and labels.
FocusNode _byLabel(String label) => FocusManager.instance.rootScope.descendants
    .firstWhere((node) => node.debugLabel == label);

/// The focus node behind an icon button, via the InkWell's Focus that carries
/// the button's node.
FocusNode _button(WidgetTester tester, String tooltip) {
  return tester
      .widgetList<Focus>(
        find.descendant(
          of: find.byTooltip(tooltip),
          matching: find.byType(Focus),
        ),
      )
      .firstWhere((focus) => focus.focusNode != null)
      .focusNode!;
}

/// The seek bar's own focus node. The controls hand it no node, so the bar
/// makes its own - and labels it, which is the only way a focus test can name
/// the one control that is not a button.
FocusNode _scrubber() => _byLabel('player-seek-bar');

bool _inChrome(FocusNode node) =>
    node.ancestors.any((n) => n.debugLabel == 'player-chrome');

/// The Skip chip's own focus node - the one carrying its key handler.
///
/// [PlayerActionButton] is a [Focus] over an [InkWell], and InkWell makes a
/// focus node of its own, so the chip owns two. The one that matters is the
/// outer wrapper, which is the first [Focus] inside the button in tree order;
/// it is unlabelled, so it is resolved by matching a node's context to that
/// element rather than by name.
FocusNode _skipChipNode(WidgetTester tester) {
  final Element wrapper = tester.element(
    find
        .descendant(
          of: find.ancestor(
            of: find.byIcon(Icons.fast_forward_rounded),
            matching: find.byType(PlayerActionButton),
          ),
          matching: find.byType(Focus),
        )
        .first,
  );
  return FocusManager.instance.rootScope.descendants.firstWhere(
    (node) => node.context == wrapper,
  );
}

/// Read off the fades' targets, so it does not wait on the animation.
Iterable<AnimatedOpacity> _fades(WidgetTester tester) =>
    tester.widgetList<AnimatedOpacity>(
      find.descendant(
        of: find.byType(VlcPlayerControls),
        matching: find.byType(AnimatedOpacity),
      ),
    );

void _expectShown(WidgetTester tester, {String? reason}) {
  final fades = _fades(tester);
  expect(fades, isNotEmpty);
  expect(fades.map((f) => f.opacity), everyElement(1.0), reason: reason);
}

void _expectHidden(WidgetTester tester, {String? reason}) {
  final fades = _fades(tester);
  expect(fades, isNotEmpty);
  expect(fades.map((f) => f.opacity), everyElement(0.0), reason: reason);
}

/// Runs the clock out and lets the frame that hides the chrome settle,
/// including the focus microtasks and the mouse tracker's post-frame pass.
Future<void> _letHide(WidgetTester tester) async {
  await tester.pump(_hideAfter);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VlcPlayerControls focus on TV', () {
    testWidgets('the remote starts on play/pause', (tester) async {
      await _pumpControls(tester);
      expect(_primary.debugLabel, 'player-play-pause');
    });

    // The panel is a route of its own, so the chrome underneath it keeps
    // ticking. Without a hold the bars fade out behind the open panel, their
    // ExcludeFocus makes the button that opened it unfocusable, and closing
    // returns focus to nothing: the stranded remote.
    testWidgets('an open panel holds the chrome up for as long as it lives', (
      tester,
    ) async {
      final panel = Completer<void>();
      await _pumpControls(tester, onOpenPanel: (_) => panel.future);

      await tester.tap(find.byTooltip('Sources'));
      await tester.pump();

      // Well past the hide clock, and past the one re-arm _expire grants a
      // player it thinks is paused: a poke-and-forget cannot survive this.
      await _letHide(tester);
      await _letHide(tester);
      await _letHide(tester);
      _expectShown(tester, reason: 'the panel is still open');

      panel.complete();
      await tester.pump();
      await _letHide(tester);
      await _letHide(tester);
      await _letHide(tester);
      _expectHidden(tester, reason: 'the hold ended with the panel');
    });

    testWidgets('hiding hands focus to the sink, never the route scope', (
      tester,
    ) async {
      await _pumpControls(tester);
      await _letHide(tester);

      _expectHidden(tester);
      expect(_primary, isNot(isA<FocusScopeNode>()));
      expect(_primary.debugLabel, 'player-key-sink');
    });

    testWidgets('Back does not summon hidden chrome', (tester) async {
      // Android delivers Back as a key first and a popRoute second. If the key
      // raised the bars, the screen's Back handler then found them up and put
      // them away instead of leaving - the player could not be exited while
      // playing. Back belongs to the screen; the sink must not touch it.
      await _pumpControls(tester);
      await _letHide(tester);
      _expectHidden(tester);

      await tester.sendKeyEvent(
        LogicalKeyboardKey.goBack,
        // flutter_test has no physical key on file for Go Back, and no
        // Windows key code for it either; Android's table has both. The
        // controls only ever read the logical key.
        platform: 'android',
        physicalKey: PhysicalKeyboardKey.escape,
      );
      await tester.pump();

      _expectHidden(tester, reason: 'Back is not ours to react to');
    });

    testWidgets('select while hidden brings the chrome back on play/pause', (
      tester,
    ) async {
      await _pumpControls(tester);
      await _letHide(tester);
      _expectHidden(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();

      _expectShown(tester);
      expect(_primary.debugLabel, 'player-play-pause');
    });

    testWidgets('every arrow from play/pause stays on a chrome node', (
      tester,
    ) async {
      await _pumpControls(tester);

      for (final arrow in <LogicalKeyboardKey>[
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
      ]) {
        _byLabel('player-play-pause').requestFocus();
        await tester.pump();
        expect(_primary.debugLabel, 'player-play-pause');

        await tester.sendKeyEvent(arrow);
        await tester.pump();

        expect(
          _inChrome(_primary),
          isTrue,
          reason:
              '${arrow.keyLabel.isEmpty ? arrow.debugName : arrow.keyLabel} '
              'from play/pause landed on ${_primary.debugLabel}; the sink is '
              'not a traversal candidate and the scope is never focused',
        );
      }
    });

    // The headline TV defect. Key dispatch runs the focused node first and
    // stops at the first widget that claims the key, so while the seek bar
    // answered Up and Down itself the player's sink - the only thing that
    // restarts the hide clock - never saw them. Land on the scrubber at 2.9 s
    // of a 3 s clock, press Up, and the bars went down 0.1 s later with the
    // remote halfway through navigating.
    testWidgets('moving the D-pad off the scrubber restarts the hide clock', (
      tester,
    ) async {
      await _pumpControls(tester);
      _scrubber().requestFocus();
      await tester.pump();
      expect(_primary.debugLabel, 'player-seek-bar');

      // 200 ms short of the clock: the bars are about to go.
      await tester.pump(_hideAfter - const Duration(milliseconds: 200));
      _expectShown(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      _expectShown(
        tester,
        reason: 'the press that moved focus is a press; the clock restarts',
      );
      expect(_inChrome(_primary), isTrue);
    });

    // The other half of the same rule: a press the bar cannot act on is not
    // the bar's to swallow. At position 0 a Left step clamps to where the
    // thumb already is, and the bar used to report that dead press handled -
    // no seek, no poke, and the bars timing out under a viewer who is
    // pressing a button.
    testWidgets('a clamped scrubber press seeks nothing but still pokes', (
      tester,
    ) async {
      final engine = FakeVlcEngine();
      await _pumpControls(tester, engine: engine);
      engine.calls.clear();
      _scrubber().requestFocus();
      await tester.pump();

      await tester.pump(_hideAfter - const Duration(milliseconds: 200));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      expect(
        _seeks(engine),
        isEmpty,
        reason: 'playback is at 0; there is nothing to the left',
      );
      _expectShown(tester, reason: 'a dead press is still a press');
    });

    // The arrows off the scrubber are now DirectionalFocusAction's, so the
    // geometry has to work: Up crosses the Expanded spacer between the two
    // bars to reach the top bar, and Down crosses the FocusTraversalGroup
    // boundary around the button row underneath.
    testWidgets('every arrow from the scrubber stays on a chrome node, and '
        'Up and Down reach the bars', (tester) async {
      await _pumpControls(tester);

      for (final arrow in <LogicalKeyboardKey>[
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
      ]) {
        _scrubber().requestFocus();
        await tester.pump();
        expect(_primary.debugLabel, 'player-seek-bar');

        await tester.sendKeyEvent(arrow);
        await tester.pump();

        expect(
          _inChrome(_primary),
          isTrue,
          reason:
              '${arrow.keyLabel.isEmpty ? arrow.debugName : arrow.keyLabel} '
              'from the scrubber landed on ${_primary.debugLabel}',
        );
      }

      // The Right in the loop opened a burst; let it commit and let the
      // chain window that follows it close, so no timer outlives the test.
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      await _snapshot(tester, state: 'paused');
    });

    // Each direction gets its own test on purpose: the directional policy
    // keeps a per-scope history so that reversing a move returns to where it
    // came from, and pressing Up then Down inside one test measures that
    // hysteresis rather than the geometry.
    testWidgets('Up walks play/pause to the scrubber and on to the top bar', (
      tester,
    ) async {
      await _pumpControls(tester);
      expect(_primary.debugLabel, 'player-play-pause');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(_primary.debugLabel, 'player-seek-bar');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(
        _primary,
        _button(tester, 'Back'),
        reason: 'the bars are a Column apart, with an Expanded between them',
      );
    });

    testWidgets('Down from the scrubber crosses into the button row', (
      tester,
    ) async {
      await _pumpControls(tester);
      final scrubber = _scrubber();
      scrubber.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();

      expect(_primary, isNot(scrubber));
      expect(_inChrome(_primary), isTrue);
      expect(
        _primary.rect.top,
        greaterThanOrEqualTo(scrubber.rect.bottom),
        reason:
            'the row under the scrubber is its own FocusTraversalGroup; '
            'geometric traversal has to cross into it',
      );
    });

    // The last player control with no ten-foot treatment. isTv was declared on
    // VlcProgressBar, passed by the controls, and read by nobody.
    testWidgets('the scrubber is sized for a sofa on TV', (tester) async {
      await _pumpControls(tester);
      expect(tester.getSize(find.byType(PlayerSeekBar)).height, 48);
    });

    testWidgets('a parked remote does not pin the chrome, but comes back '
        'where it left', (tester) async {
      await _pumpControls(tester);

      // Rest on Subtitles. Focus alone must not hold the bars: on a
      // television focus is always on *some* control while the chrome is up,
      // so a hold-while-focused rule would mean the chrome never hides.
      final subtitles = _button(tester, 'Subtitles');
      subtitles.requestFocus();
      await tester.pump();
      expect(_primary, subtitles);

      await _letHide(tester);
      _expectHidden(
        tester,
        reason: 'static focus on a button must not keep the video covered',
      );
      expect(_primary.debugLabel, 'player-key-sink');

      // Instead the courtesy is that nothing is lost: the next press brings
      // the bars back with focus exactly where it was.
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      _expectShown(tester);
      expect(_primary, subtitles);
    });

    testWidgets('a D-pad seek holds the chrome, then lets it go', (
      tester,
    ) async {
      await _pumpControls(tester);

      // Up from play/pause is the scrubber; Right on the scrubber seeks.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(_primary.debugLabel, isNot('player-play-pause'));
      expect(_inChrome(_primary), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      // The seek bar commits a burst 500 ms after the last press and only
      // then may the clock restart, so at the old timeout the bars are still
      // up - and a little later they are not, which is the half the old code
      // got wrong: it cancelled the timer on seek start and nothing re-armed.
      await tester.pump(_hideAfter);
      _expectShown(tester, reason: 'the seek held the clock');
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      _expectHidden(tester, reason: 'the seek ended; the clock re-armed');
    });

    // The hold the bar takes on seek start is counted, and release() is the
    // only thing that gives one back. Every way out of a burst has to reach
    // one: here the media is reopened on the same controller mid-burst - a
    // failover - the duration drops back to zero and the scrubber's own end
    // callback is nulled before the burst's 500 ms commit fires. Nothing
    // below can report the end, so the bar reports it itself; otherwise the
    // bars stay up for the rest of the session.
    testWidgets('a burst the bar can no longer commit still releases the '
        'chrome', (tester) async {
      final chrome = ChromeVisibilityController(isPlaying: () => true);
      await _pumpControls(tester, chrome: chrome);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(chrome.isHeld, isTrue, reason: 'the burst holds the chrome');

      // The screen reopened the media on the same controller: no length yet.
      await _snapshot(tester, duration: 0);
      // Past the burst's commit timer, which now has nothing to commit to.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      expect(
        chrome.isHeld,
        isFalse,
        reason: 'the seek is gone; the hold cannot outlive it',
      );
      await _letHide(tester);
      _expectHidden(tester, reason: 'the clock re-armed');

      await _snapshot(tester, state: 'paused');
      chrome.dispose();
    });

    // The other way out: the player leaves - Back, a failover that rebuilds
    // the tree - with a burst still in flight. The chrome is the screen's and
    // outlives these controls, so a hold left behind pins the next media's
    // bars up instead.
    testWidgets('the controls going away mid-burst release the chrome', (
      tester,
    ) async {
      final chrome = ChromeVisibilityController(isPlaying: () => true);
      await _pumpControls(tester, chrome: chrome);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(chrome.isHeld, isTrue);

      await tester.pumpWidget(const SizedBox.shrink());

      expect(
        chrome.isHeld,
        isFalse,
        reason: 'the hold went out with the controls that took it',
      );
      chrome.dispose();
    });
  });

  group('VlcPlayerControls list buttons', () {
    // Five buttons, one callback, one panel. Each button opens the panel on
    // its own tab and holds the chrome for the panel's life, so the control
    // focus returns to is still there when the panel pops.
    for (final (String Function(AppLocalizations) tooltip, PlayerPanelTab tab)
        in <(String Function(AppLocalizations), PlayerPanelTab)>[
          ((l10n) => l10n.sources, PlayerPanelTab.sources),
          ((l10n) => l10n.audioTracks, PlayerPanelTab.audio),
          ((l10n) => l10n.subtitles, PlayerPanelTab.subtitles),
          ((l10n) => l10n.episodes, PlayerPanelTab.episodes),
          ((l10n) => l10n.torrentFiles, PlayerPanelTab.files),
        ]) {
      testWidgets('${tab.name}: opens the panel on its tab and holds the '
          'chrome until it closes', (tester) async {
        final l10n = await AppLocalizations.delegate.load(const Locale('en'));
        final panel = Completer<void>();
        final opened = <PlayerPanelTab>[];
        await _pumpControls(
          tester,
          onOpenPanel: (tab) {
            opened.add(tab);
            return panel.future;
          },
        );

        await tester.tap(find.byTooltip(tooltip(l10n)));
        // The screen-wide detector also owns a double-tap, so a single tap on
        // a button resolves only after that recogniser gives up.
        await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
        expect(opened, <PlayerPanelTab>[tab]);

        await _letHide(tester);
        await _letHide(tester);
        _expectShown(tester, reason: 'the panel is still open');

        panel.complete();
        await tester.pump();
        await _letHide(tester);
        await _letHide(tester);
        _expectHidden(tester, reason: 'the hold ended with the panel');
      });
    }

    testWidgets('Subtitles opens the panel; no sheet remains', (tester) async {
      // The track sheet is gone: the panel is the one surface for every list,
      // so Back and focus obey one set of rules everywhere.
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final opened = <PlayerPanelTab>[];
      await _pumpControls(tester, onOpenPanel: (tab) async => opened.add(tab));

      await tester.tap(find.byTooltip(l10n.subtitles));
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
      await tester.pump();

      expect(find.byType(BottomSheet), findsNothing);
      expect(opened, <PlayerPanelTab>[PlayerPanelTab.subtitles]);
    });

    // Absent, not disabled: focus must never land on a control whose list
    // does not exist. One helper decides both the strip and the bar.
    testWidgets('no Episodes or Files button without those tabs', (
      tester,
    ) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      await _pumpControls(
        tester,
        panelTabs: const <PlayerPanelTab>{
          PlayerPanelTab.sources,
          PlayerPanelTab.audio,
          PlayerPanelTab.subtitles,
        },
      );

      expect(find.byTooltip(l10n.episodes), findsNothing);
      expect(find.byTooltip(l10n.torrentFiles), findsNothing);
      expect(find.byTooltip(l10n.sources), findsOneWidget);
    });

    testWidgets('no Sources button without the tab; Audio and Subtitles stay', (
      tester,
    ) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      await _pumpControls(
        tester,
        panelTabs: const <PlayerPanelTab>{
          PlayerPanelTab.audio,
          PlayerPanelTab.subtitles,
        },
      );

      expect(find.byTooltip(l10n.sources), findsNothing);
      expect(
        find.byTooltip(l10n.audioTracks),
        findsOneWidget,
        reason: 'always present: an empty list is still something to say',
      );
      expect(find.byTooltip(l10n.subtitles), findsOneWidget);
    });

    testWidgets('Episodes follows the same setting as Next', (tester) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      await _pumpControls(
        tester,
        settings: const PlayerSettings(showEpisodes: false),
      );

      expect(find.byTooltip(l10n.episodes), findsNothing);
      expect(find.byTooltip(l10n.next), findsNothing);
      expect(find.byTooltip(l10n.subtitles), findsOneWidget);
    });

    testWidgets('with no panel to open there is no list button at all', (
      tester,
    ) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      await _pumpControls(tester, withoutPanel: true);

      for (final tooltip in <String>[
        l10n.sources,
        l10n.audioTracks,
        l10n.subtitles,
        l10n.episodes,
        l10n.torrentFiles,
      ]) {
        expect(find.byTooltip(tooltip), findsNothing, reason: tooltip);
      }
      expect(find.byTooltip(l10n.pause), findsOneWidget);
    });
  });

  group('VlcPlayerControls with an injected chrome controller', () {
    // The screen needs to drop the chrome on Back before it pops and hold it
    // while a panel is up. Both are its calls about a thing the controls
    // own, so the controls must follow a controller they did not make - and
    // must not kill it on the way out, since the screen outlives them across
    // every failover and episode advance.
    testWidgets('the bars follow it and it survives the controls', (
      tester,
    ) async {
      final chrome = ChromeVisibilityController(isPlaying: () => true);
      await _pumpControls(tester, chrome: chrome);
      _expectShown(tester);

      chrome.toggle();
      await tester.pump();
      _expectHidden(tester, reason: 'hidden from outside the controls');

      chrome.poke();
      await tester.pump();
      _expectShown(tester, reason: 'revealed from outside the controls');

      await tester.pumpWidget(const SizedBox.shrink());
      // A disposed notifier refuses new listeners; a live one takes them, and
      // its hide clock is still armed - which is why the owner, not a
      // teardown, has to be the one to stop it.
      expect(() => chrome.addListener(() {}), returnsNormally);
      expect(chrome.value, isTrue);
      chrome.dispose();
    });
  });

  group('VlcPlayerControls during a stall', () {
    // Off Android, libVLC keeps reporting `playing` through a rebuffer, so a
    // spinner keyed on the state never showed: a frozen frame under a pause
    // glyph for up to 25 s. The controller raises isStalled from the position
    // clock instead, and the chrome has to read it. On Android the engine
    // does say `buffering`, and the film will resume on its own, so the glyph
    // must keep offering pause rather than claim the player is stopped.
    testWidgets('a frozen clock shows the spinner; motion clears it', (
      tester,
    ) async {
      final controller = await _pumpControls(tester);
      await _snapshot(tester, position: 1000);
      await _snapshot(tester, position: 1000);
      expect(find.byType(PlayerBufferingIndicator), findsNothing);

      await tester.pump(controller.stallIndicatorDelay);
      expect(controller.value.isStalled, isTrue);
      expect(controller.value.isBuffering, isFalse);
      expect(
        find.byType(PlayerBufferingIndicator),
        findsOneWidget,
        reason: 'the spinner follows the stall, not the libVLC state',
      );

      await _snapshot(tester, position: 2000);
      expect(controller.value.isStalled, isFalse);
      expect(find.byType(PlayerBufferingIndicator), findsNothing);

      // A playing controller keeps its stall watchdog armed, and flutter_test
      // checks for pending timers before the harness's tearDown disposes it.
      // Pause parks the clock.
      await _snapshot(tester, state: 'paused', position: 2000);
    });

    testWidgets('a rebuffer keeps the pause glyph', (tester) async {
      await _pumpControls(tester);
      await _snapshot(tester, position: 1000);
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);

      // Same position as the last tick: an advancing one would be the
      // healthy-playback flap the value layer corrects back to `playing`.
      await _snapshot(tester, state: 'buffering', position: 1000);
      expect(find.byType(PlayerBufferingIndicator), findsOneWidget);
      expect(
        find.byIcon(Icons.pause_rounded),
        findsOneWidget,
        reason: 'playback will resume, so the button still offers pause',
      );
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);

      // The engine catches up: the spinner goes and the glyph never moved.
      await _snapshot(tester, position: 2000);
      expect(find.byType(PlayerBufferingIndicator), findsNothing);
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);

      // A playing controller keeps its stall watchdog armed, and flutter_test
      // checks for pending timers before the harness's tearDown disposes it.
      // Pause parks the clock.
      await _snapshot(tester, state: 'paused', position: 2000);
    });
  });

  group('VlcPlayerControls keyboard on desktop', () {
    testWidgets('the scrubber keeps its compact size off TV', (tester) async {
      await _pumpControls(tester, isTv: false, desktop: true);
      expect(tester.getSize(find.byType(PlayerSeekBar)).height, 36);
    });

    // Space is the activation key for whatever is focused. Claiming it as a
    // global play/pause toggle means Space on a focused Next button toggles
    // playback instead of pressing Next; the old player guarded exactly this
    // on rootHasFocus. K and the media keys stay global by convention.
    testWidgets('Space presses the focused button, and toggles playback only '
        'from the sink', (tester) async {
      final engine = FakeVlcEngine();
      var nextPressed = 0;
      await _pumpControls(
        tester,
        isTv: false,
        desktop: true,
        onNextEpisode: () => nextPressed++,
        engine: engine,
      );
      engine.calls.clear();

      _button(tester, 'Next').requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(nextPressed, 1, reason: 'Space activates the focused button');
      expect(
        engine.methods.where((m) => m == 'play' || m == 'pause'),
        isEmpty,
        reason: 'playback was not touched',
      );

      _byLabel('player-key-sink').requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(
        engine.methods,
        contains('pause'),
        reason: 'bare Space toggles playback',
      );
      expect(nextPressed, 1);
    });

    // Hold-to-2x existed on a touch long-press only, so the same gesture was
    // missing from every keyboard. Space is the natural key and it is already
    // the bare play/pause toggle, so the two share it the way tap and
    // long-press share the video surface: the down press claims the key and
    // commits to nothing, the first auto-repeat starts the boost, and the
    // release either gives the speed back or - never having repeated - is the
    // toggle.
    //
    // The first expectation is the one that matters. Toggling on the down
    // press instead - the wiring that looks right - pauses the film under a
    // viewer who meant to skim, and it is still paused when they let go. (On
    // a device it is inert as well, since _startSpeedBoost wants something
    // playing and the engine has published the pause by the time the key
    // repeats; the fake never echoes a pause back, so the pause itself is the
    // half of that this can see.)
    testWidgets('holding Space runs at 2x, and the release gives it back', (
      tester,
    ) async {
      final engine = FakeVlcEngine();
      await _pumpControls(tester, isTv: false, desktop: true, engine: engine);
      _byLabel('player-key-sink').requestFocus();
      await tester.pump();
      engine.calls.clear();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(
        engine.methods,
        isEmpty,
        reason: 'the down press only claims the key; the release decides',
      );

      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(_speeds(engine), <double>[2.0]);
      expect(find.text('2x'), findsOneWidget);
      expect(
        engine.methods.where((m) => m == 'play' || m == 'pause'),
        isEmpty,
        reason: 'a hold is not a toggle',
      );

      // Idempotent: a key held down repeats many times over, and every
      // further repeat must be a poke and nothing else.
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(_speeds(engine), <double>[2.0]);

      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(
        _speeds(engine),
        <double>[2.0, 1.0],
        reason: 'the release restores the speed the hold interrupted',
      );
      expect(find.text('2x'), findsNothing);
      expect(
        engine.methods.where((m) => m == 'play' || m == 'pause'),
        isEmpty,
        reason: 'a release that ended a hold is not also a tap',
      );

      await _snapshot(tester, state: 'paused');
    });

    // The same guard the tap has, on the other two events. Space belongs to
    // whatever is focused, so a held Space on a focused button must repeat
    // that button and never touch the playback rate.
    testWidgets('holding Space on a focused button never boosts', (
      tester,
    ) async {
      final engine = FakeVlcEngine();
      var nextPressed = 0;
      await _pumpControls(
        tester,
        isTv: false,
        desktop: true,
        onNextEpisode: () => nextPressed++,
        engine: engine,
      );
      _button(tester, 'Next').requestFocus();
      await tester.pump();
      engine.calls.clear();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump();
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump();

      expect(_speeds(engine), isEmpty, reason: 'Space belonged to the button');
      expect(
        engine.methods.where((m) => m == 'play' || m == 'pause'),
        isEmpty,
        reason: 'and the release is not a deferred toggle either',
      );
      expect(nextPressed, greaterThanOrEqualTo(1));

      await _snapshot(tester, state: 'paused');
    });
  });

  group('VlcPlayerControls mouse on desktop', () {
    testWidgets('a moving mouse reveals hidden chrome; a resting one does '
        'not keep it up', (tester) async {
      await _pumpControls(tester, isTv: false, desktop: true);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      final centre = tester.getCenter(find.byType(VlcPlayerControls));
      await mouse.addPointer(location: centre);
      await tester.pump();

      // The cursor sits on the video the whole time the clock runs.
      await _letHide(tester);
      _expectHidden(tester, reason: 'a stationary cursor is not activity');

      await mouse.moveTo(centre + const Offset(40, 0));
      await tester.pump();
      _expectShown(tester);
    });

    testWidgets('the bars do not go while the mouse rests on them', (
      tester,
    ) async {
      await _pumpControls(tester, isTv: false, desktop: true);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(
        location: tester.getCenter(find.byTooltip('Pause')),
      );
      await tester.pump();

      await _letHide(tester);
      _expectShown(tester, reason: 'hovering a bar holds it');

      await mouse.moveTo(tester.getCenter(find.byType(VlcPlayerControls)));
      await tester.pump();
      await _letHide(tester);
      _expectHidden(tester, reason: 'leaving the bar re-arms the clock');
    });

    testWidgets('the cursor hides with the chrome and returns with it', (
      tester,
    ) async {
      final kinds = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.mouseCursor,
        (call) async {
          if (call.method == 'activateSystemCursor') {
            kinds.add(
              (call.arguments as Map<Object?, Object?>)['kind']! as String,
            );
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.mouseCursor,
          null,
        ),
      );

      await _pumpControls(tester, isTv: false, desktop: true);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      final centre = tester.getCenter(find.byType(VlcPlayerControls));
      await mouse.addPointer(location: centre);
      await tester.pump();
      expect(kinds.last, 'basic', reason: 'visible chrome defers the cursor');

      await _letHide(tester);
      _expectHidden(tester);
      expect(kinds.last, 'none');

      await mouse.moveTo(centre + const Offset(40, 0));
      await tester.pump();
      await tester.pump();
      _expectShown(tester);
      expect(kinds.last, 'basic');
    });

    // The hold a hovered bar takes is counted, and release() is the only
    // thing that gives one back. Flutter deliberately does not deliver
    // MouseRegion.onExit when the region is unmounted with the pointer still
    // inside it, and the bar goes out from under the cursor every time the
    // controls leave: a failover that clears the frame flag, an episode
    // advance, Back, entering PiP. The chrome is the screen's and outlives
    // them, so a stranded hold pins the next media's bars up for good.
    testWidgets('the controls going away under the cursor give the hover '
        'hold back', (tester) async {
      final chrome = ChromeVisibilityController(isPlaying: () => true);
      await _pumpControls(tester, isTv: false, desktop: true, chrome: chrome);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(
        location: tester.getCenter(find.byTooltip('Pause')),
      );
      await tester.pump();
      expect(chrome.isHeld, isTrue, reason: 'hovering a bar holds the chrome');

      await tester.pumpWidget(const SizedBox.shrink());

      expect(
        chrome.isHeld,
        isFalse,
        reason: 'the hold went out with the bar that took it',
      );
      chrome.dispose();
    });

    // And the half a teardown backstop in the controls would not catch: the
    // hovered subtree can go while the controls stay - hover exists only
    // where a window can toggle fullscreen, so withdrawing that affordance
    // takes the region out from under a pointer that is still there. The
    // release belongs to whatever owns the region, not to the controls.
    testWidgets('a hovered bar taken away on its own gives the hold back, '
        'and the clock re-arms', (tester) async {
      final chrome = ChromeVisibilityController(isPlaying: () => true);
      final controller = await _pumpControls(
        tester,
        isTv: false,
        desktop: true,
        chrome: chrome,
      );
      final state = tester.state(find.byType(VlcPlayerControls));

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(
        location: tester.getCenter(find.byTooltip('Pause')),
      );
      await tester.pump();
      expect(chrome.isHeld, isTrue, reason: 'hovering a bar holds the chrome');

      await tester.pumpWidget(
        _host(
          VlcPlayerControls(
            controller: controller,
            chrome: chrome,
            title: 'The Body',
            subtitle: 'S5 E16',
            onBack: () {},
            onNextEpisode: () {},
            onOpenPanel: _noPanel,
            panelTabs: _allTabs,
            onToggleFullscreen: null,
          ),
          isTv: false,
        ),
      );
      await tester.pump();

      expect(
        tester.state(find.byType(VlcPlayerControls)),
        same(state),
        reason: 'only the hover region went; the controls are still here',
      );
      expect(
        chrome.isHeld,
        isFalse,
        reason: 'the hold cannot outlive the region that took it',
      );
      await _letHide(tester);
      _expectHidden(tester, reason: 'the clock re-armed');
      chrome.dispose();
    });
  });

  group('VlcPlayerControls relative seeks', () {
    // The controller publishes only the engine's position, and the engine's
    // read-back of a seek arrives a snapshot later. A second step in that
    // window used to count from the stale position and undo the first; now
    // it counts from the last target for as long as the progress bar would
    // latch it - stallIndicatorDelay + 500 ms - and from the truth after.
    testWidgets('a second L before the engine answers counts from the first '
        'target, and from the truth once the window closes', (tester) async {
      final engine = FakeVlcEngine();
      final controller = await _pumpControls(
        tester,
        isTv: false,
        desktop: true,
        engine: engine,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(_seeks(engine), [10000, 20000], reason: 'chained, not undone');

      // No snapshot ever comes. Past the window the base is the controller
      // again, whose position is still 0: the truth, not a guess.
      await tester.pump(
        controller.stallIndicatorDelay + const Duration(milliseconds: 600),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(_seeks(engine), [10000, 20000, 10000]);

      await _snapshot(tester, state: 'paused', position: 10000);
    });

    testWidgets('two double-taps on the right half accumulate', (tester) async {
      final engine = FakeVlcEngine();
      await _pumpControls(tester, isTv: false, engine: engine);
      final right =
          tester.getCenter(find.byType(VlcPlayerControls)) +
          const Offset(400, 0);

      // Every pointer-down arms the double-tap recogniser's 40 ms minimum-gap
      // countdown, which nothing cancels; the trailing pump lets it lapse so
      // the test does not end with it pending.
      Future<void> doubleTap() async {
        await tester.tapAt(right);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(right);
        await tester.pump(const Duration(milliseconds: 50));
      }

      await doubleTap();
      expect(_seeks(engine), [10000]);
      await doubleTap();
      expect(_seeks(engine), [10000, 20000]);

      await _snapshot(tester, state: 'paused', position: 20000);
    });

    // The pre-migration player showed a screen-centred pill here, byte for
    // byte the same one the swipe, the 2x boost and the resize cycle use. It
    // said nothing about which half had been tapped, so a viewer who hit the
    // wrong side got a confirmation that looked exactly like a correct one -
    // and it always printed the bare step, never the running total.
    testWidgets('a double-tap on the right half shows a forward burst, not '
        'the centre pill', (tester) async {
      final engine = FakeVlcEngine();
      await _pumpControls(tester, isTv: false, engine: engine);
      final centre = tester.getCenter(find.byType(VlcPlayerControls));
      final right = centre + const Offset(400, 0);

      Future<void> doubleTap(Offset at) async {
        await tester.tapAt(at);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(at);
        await tester.pump(const Duration(milliseconds: 50));
      }

      await doubleTap(right);
      expect(_seeks(engine), [10000]);
      expect(find.byType(PlayerToast), findsNothing, reason: 'no centre pill');
      final burst = tester.widget<PlayerSeekBurst>(
        find.byType(PlayerSeekBurst),
      );
      expect(burst.forward, isTrue, reason: 'the right half was tapped');
      expect(find.text('10s'), findsOneWidget);

      // The burst is on the right of the frame, not in the middle of it -
      // which is the whole point and the only part a viewer can see. Measured
      // off the readout, not off PlayerSeekBurst: its outermost widget is an
      // Align, which takes the whole viewport and is centred by definition.
      expect(
        tester.getCenter(find.text('10s')).dx,
        greaterThan(centre.dx),
        reason: 'the readout says which half fired by being on it',
      );
      // And it does not land on the centre play/pause, which is the other
      // thing living in the middle of a touch frame.
      expect(
        tester
            .getRect(find.byType(PlayerCenterPlayButton))
            .overlaps(tester.getRect(find.text('10s'))),
        isFalse,
        reason: 'the burst and the centre glyph must not sit on each other',
      );

      await doubleTap(right);
      expect(_seeks(engine), [10000, 20000]);
      expect(
        find.text('20s'),
        findsOneWidget,
        reason: 'the chain total, not the bare step',
      );
      expect(find.text('10s'), findsNothing);

      await _snapshot(tester, state: 'paused', position: 20000);
    });

    testWidgets('and the left half gets a backward burst on its own side', (
      tester,
    ) async {
      final engine = FakeVlcEngine();
      await _pumpControls(tester, isTv: false, engine: engine);
      await _snapshot(tester, position: 30000, duration: 120000);
      final centre = tester.getCenter(find.byType(VlcPlayerControls));
      final left = centre - const Offset(400, 0);

      await tester.tapAt(left);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(left);
      await tester.pump(const Duration(milliseconds: 50));

      expect(_seeks(engine), [20000]);
      final burst = tester.widget<PlayerSeekBurst>(
        find.byType(PlayerSeekBurst),
      );
      expect(burst.forward, isFalse);
      expect(find.text('10s'), findsOneWidget);
      expect(
        tester.getCenter(find.text('10s')).dx,
        lessThan(centre.dx),
        reason: 'the readout says which half fired by being on it',
      );

      await _snapshot(tester, state: 'paused', position: 20000);
    });

    testWidgets('J and L keep the centred pill, never the side burst', (
      tester,
    ) async {
      final engine = FakeVlcEngine();
      await _pumpControls(tester, isTv: false, engine: engine);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(find.text('+10s'), findsOneWidget);
      expect(find.byType(PlayerSeekBurst), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.pump();
      expect(find.text('+0s'), findsOneWidget, reason: 'back to the start');
      expect(
        find.byType(PlayerSeekBurst),
        findsNothing,
        reason:
            'the burst says which half of the screen fired; a keypress has '
            'no half, so routing the keyboard through it would be a lie',
      );

      await _snapshot(tester, state: 'paused');
    });

    // On a pad the shoulder buttons are the whole seek affordance. Without
    // them, seeking with a controller meant waking the chrome, walking the
    // D-pad down to the scrubber and only then pressing Left or Right - four
    // presses for what LB and RB do in one. They are routed through the same
    // _seekBy as J and L rather than a parallel mechanism, so they inherit
    // the chain window and the centred pill for free.
    testWidgets(
      'LB and RB seek by the configured step and chain like J and L',
      (tester) async {
        final engine = FakeVlcEngine();
        await _pumpControls(tester, engine: engine);
        await _snapshot(tester, position: 10000);
        engine.calls.clear();

        await _shoulder(tester, LogicalKeyboardKey.gameButtonRight1);
        expect(_seeks(engine), <int>[20000]);

        // Still inside the window and no snapshot has come back: the second
        // press counts from the first target, exactly as a second L does.
        await _shoulder(tester, LogicalKeyboardKey.gameButtonRight1);
        expect(
          _seeks(engine),
          <int>[20000, 30000],
          reason: 'chained, not undone',
        );
        expect(find.text('+20s'), findsOneWidget, reason: 'the shared toast');
        expect(
          find.byType(PlayerSeekBurst),
          findsNothing,
          reason: 'a button press has no half of the screen to point at',
        );

        await _shoulder(tester, LogicalKeyboardKey.gameButtonLeft1);
        expect(_seeks(engine), <int>[20000, 30000, 20000]);
        expect(find.text('+10s'), findsOneWidget);

        await _snapshot(tester, state: 'paused', position: 20000);
      },
    );

    // A shoulder button has no traversal meaning and no activation meaning,
    // which is exactly why it is bound: unlike a bare arrow it does not have
    // to be given up to the focus system when a control is focused, and
    // unlike a bare arrow on television it is not spent revealing the chrome.
    testWidgets('a shoulder press seeks with a control focused, and the press '
        'that wakes the bars seeks too', (tester) async {
      final engine = FakeVlcEngine();
      await _pumpControls(tester, engine: engine);
      expect(_primary.debugLabel, 'player-play-pause');
      engine.calls.clear();

      await _shoulder(tester, LogicalKeyboardKey.gameButtonRight1);
      expect(
        _seeks(engine),
        <int>[10000],
        reason: 'the focused play/pause is not a traversal stop for LB/RB',
      );
      expect(
        engine.methods.where((m) => m == 'play' || m == 'pause'),
        isEmpty,
        reason: 'the button under focus was not pressed',
      );

      // Past the chain window, so the second press counts from the engine's
      // position - still 0 - rather than from the first target.
      await _letHide(tester);
      _expectHidden(tester);

      await _shoulder(tester, LogicalKeyboardKey.gameButtonRight1);
      expect(
        _seeks(engine),
        <int>[10000, 10000],
        reason:
            'a bare arrow on TV is spent on the reveal; a shoulder button is '
            'unambiguous and seeks as well',
      );
      _expectShown(tester);

      await _snapshot(tester, state: 'paused', position: 10000);
    });

    // The chain counts from its own target for a second and a half, and the
    // scrubber is reachable throughout: a click on the track lands somewhere
    // the chain knows nothing about, and the engine will not publish it for a
    // round trip. The next arrow must step on from the click - not from the
    // chain's stale target (the bug: back to where the arrows had got to) and
    // not from the engine's pre-click position either.
    testWidgets('a scrubber commit inside the window re-bases the chain, and '
        'the toast counts from there', (tester) async {
      final engine = FakeVlcEngine();
      await _pumpControls(tester, isTv: false, desktop: true, engine: engine);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(_seeks(engine), [10000]);
      expect(find.text('+10s'), findsOneWidget);
      expect(
        find.byType(PlayerSeekBurst),
        findsNothing,
        reason: 'a keypress has no half of the screen to be localised to',
      );

      // A click near the head of the track, well inside the chain's window.
      final track = tester.getRect(find.byType(PlayerSeekBar));
      await tester.tapAt(Offset(track.left + 24, track.center.dy));
      // The screen-wide double-tap recogniser holds the arena open for its
      // 300 ms gap before the scrubber's tap can win it and commit.
      await tester.pump(const Duration(milliseconds: 400));
      final clicked = _seeks(engine).last;
      expect(clicked, lessThan(5000), reason: 'the click is near the start');

      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();

      expect(_seeks(engine), [
        10000,
        clicked,
        clicked + 10000,
      ], reason: 'the arrow steps on from the click, not from the old chain');
      expect(
        find.text('+10s'),
        findsOneWidget,
        reason: 'the toast counts from the click too, not from the chain',
      );

      await _snapshot(tester, state: 'paused', position: clicked + 10000);
    });

    testWidgets('a swipe on an unseekable input never seeks', (tester) async {
      final engine = FakeVlcEngine();
      await _pumpControls(tester, isTv: false, engine: engine);
      await _snapshot(tester, position: 1000, isSeekable: false);
      final centre = tester.getCenter(find.byType(VlcPlayerControls));

      // The 50 ms lets the double-tap recogniser's minimum-gap countdown,
      // armed by the pointer-down, lapse before the test ends.
      await tester.dragFrom(centre, const Offset(300, 0));
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        engine.callsTo('seekTo'),
        isEmpty,
        reason: 'libVLC would drop the seek silently; better not to ask',
      );

      // The same swipe on a seekable one does seek, so the gate - not the
      // gesture arena - is what kept the first one quiet.
      await _snapshot(tester, position: 1000, isSeekable: true);
      await tester.dragFrom(centre, const Offset(300, 0));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_seeks(engine), hasLength(1));
      expect(_seeks(engine).single, greaterThan(1000));

      await _snapshot(tester, state: 'paused', position: 1000);
    });
  });

  // Two regressions against the pre-migration player, both touch-only. The
  // primary control was a 40 px glyph in the bottom-left corner beside the
  // scrubber, while the largest and emptiest part of the screen did nothing
  // but toggle the bars. 38da335 had an 82 px centred play/pause and
  // deliberately dropped the corner copy; the migration dropped the centre one
  // instead and kept the corner.
  group('VlcPlayerControls centre play/pause on touch', () {
    testWidgets('the touch build has one and the remote build does not', (
      tester,
    ) async {
      await _pumpControls(tester, isTv: false);
      expect(find.byType(PlayerCenterPlayButton), findsOneWidget);

      // No FocusNode anywhere inside it: it is not a traversal candidate, so
      // it cannot compete with the autofocus play/pause owns on television and
      // it cannot become an invisible stop in the middle of the frame.
      expect(
        find.descendant(
          of: find.byType(PlayerCenterPlayButton),
          matching: find.byType(Focus),
        ),
        findsNothing,
      );
    });

    testWidgets('television gets nothing in the middle of the frame', (
      tester,
    ) async {
      await _pumpControls(tester);
      expect(
        find.byType(PlayerCenterPlayButton),
        findsNothing,
        reason:
            'Select already toggles playback and play/pause already '
            'autofocuses; a control in the centre is pure downside on a remote',
      );
    });

    testWidgets('and neither does desktop, where the pointer is precise', (
      tester,
    ) async {
      await _pumpControls(tester, isTv: false, desktop: true);
      expect(find.byType(PlayerCenterPlayButton), findsNothing);
    });

    testWidgets('tapping it toggles playback and leaves focus on the sink', (
      tester,
    ) async {
      final engine = FakeVlcEngine();
      await _pumpControls(tester, isTv: false, engine: engine);

      await tester.tap(find.byType(PlayerCenterPlayButton));
      // The screen-wide detector owns a double-tap, so the single tap resolves
      // only once that recogniser gives up - the ~300 ms this control inherits
      // and deliberately keeps, because the escape from it is an opaque hit
      // test that would kill swipe-seek from dead centre.
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));

      expect(
        engine.callsTo('pause'),
        hasLength(1),
        reason: 'the glyph wins the arena over the chrome toggle beneath it',
      );
      _expectShown(tester, reason: 'a press on a control is not a hide');
      expect(
        _primary,
        same(_byLabel('player-key-sink')),
        reason: 'it takes no focus of its own; the sink still holds the keys',
      );

      await _snapshot(tester, state: 'paused');
    });

    testWidgets('one Tab lands on a chrome control, never on the glyph', (
      tester,
    ) async {
      await _pumpControls(tester, isTv: false);
      expect(_primary, same(_byLabel('player-key-sink')));

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(
        _inChrome(_primary),
        isTrue,
        reason: 'traversal walks the bars, which is where the controls are',
      );
      expect(
        find.descendant(
          of: find.byType(PlayerCenterPlayButton),
          matching: find.byType(Focus),
        ),
        findsNothing,
        reason: 'there is no node here for Tab to have landed on',
      );

      await _snapshot(tester, state: 'paused');
    });

    // The glyph sits outside `_bars`, so nothing else withdraws it when the
    // chrome goes: without its own IgnorePointer it is an invisible 88 px
    // circle in the dead centre that eats the tap-to-reveal, which is the only
    // way back on a phone. That is the single most likely way to get this
    // wrong, so it is pinned.
    testWidgets('with the bars down it is inert and the tap still reveals', (
      tester,
    ) async {
      final engine = FakeVlcEngine();
      await _pumpControls(tester, isTv: false, engine: engine);

      await _letHide(tester);
      _expectHidden(tester);

      await tester.tapAt(tester.getCenter(find.byType(VlcPlayerControls)));
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));

      expect(
        engine.callsTo('pause'),
        isEmpty,
        reason: 'an invisible glyph must not answer a tap',
      );
      _expectShown(tester, reason: 'the tap reached the chrome toggle beneath');

      await _snapshot(tester, state: 'paused');
    });

    // The toast is painted above the glyph - it is a later child of the same
    // Stack - so left centred it lands dead on the disc: every swipe readout,
    // the 2x label and the resize name, unreadable. Hiding the glyph for the
    // length of a drag is not the answer; that is a setState at pointer rate,
    // which the controls' own compositing contract forbids. So the toast moves
    // instead, and only where there is a glyph to move off.
    testWidgets('the toast is nudged clear of the glyph, not painted onto it', (
      tester,
    ) async {
      await _pumpControls(tester, isTv: false);
      final centre = tester.getCenter(find.byType(VlcPlayerControls));
      final glyph = tester.getRect(find.byType(PlayerCenterPlayButton));

      await tester.dragFrom(centre, const Offset(300, 0));
      await tester.pump();

      final message = find.descendant(
        of: find.byType(PlayerToast),
        matching: find.byType(Text),
      );
      expect(message, findsOneWidget);
      expect(
        tester.getRect(message).overlaps(glyph),
        isFalse,
        reason: 'the swipe readout is unreadable on top of the disc',
      );

      // The 50 ms lets the double-tap recogniser's minimum-gap countdown lapse.
      await tester.pump(const Duration(milliseconds: 50));
      await _snapshot(tester, state: 'paused', position: 1000);
    });

    testWidgets('and stays dead centre where there is no glyph to avoid', (
      tester,
    ) async {
      await _pumpControls(tester, isTv: false, desktop: true);
      expect(find.byType(PlayerCenterPlayButton), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();

      final message = find.descendant(
        of: find.byType(PlayerToast),
        matching: find.byType(Text),
      );
      expect(
        tester.getCenter(message).dy,
        moreOrLessEquals(
          tester.getCenter(find.byType(VlcPlayerControls)).dy,
          epsilon: 0.5,
        ),
      );

      await _snapshot(tester, state: 'paused', position: 10000);
    });

    // A rebuffer keeps offering pause, exactly as the bottom bar's copy does -
    // the film resumes without a press. A stall draws the spinner instead, and
    // the glyph collapses so the two never draw a disc around each other.
    testWidgets('a rebuffer keeps pause; a stall hands the centre to the '
        'spinner', (tester) async {
      final controller = await _pumpControls(tester, isTv: false);

      expect(
        tester
            .widget<PlayerCenterPlayButton>(find.byType(PlayerCenterPlayButton))
            .playing,
        isTrue,
      );

      // The controller raises isStalled from its own position clock: a frozen
      // position past the indicator delay is what the platforms that never
      // report `buffering` have to be caught by.
      await _snapshot(tester, position: 1000);
      await tester.pump(
        controller.stallIndicatorDelay + const Duration(milliseconds: 100),
      );
      expect(find.byType(PlayerBufferingIndicator), findsOneWidget);
      expect(
        find.byType(PlayerCenterPlayButton),
        findsNothing,
        reason: 'no disc drawn around the spinner',
      );

      await _snapshot(tester, state: 'paused', position: 1000);
    });
  });

  group('VlcPlayerControls in Big Picture', () {
    // The screen resolves its form factor through playerFormFactorOf, which
    // Big Picture widens to `tv`. The bar inside it used to read the raw
    // hardware profile instead, so a desktop wired to a television adopted the
    // ten-foot layout at the screen level and kept the phone bar inside it.
    tearDown(() => bigPictureActive.value = false);

    testWidgets('a non-TV device in Big Picture gets the ten-foot bar', (
      tester,
    ) async {
      bigPictureActive.value = true;
      await _pumpControls(tester, isTv: false);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      expect(
        find.byTooltip(l10n.volume),
        findsOneWidget,
        reason: 'the volume button is the TV-only affordance; Big Picture '
            'must reach the same verdict the screen already reaches',
      );
    });

    testWidgets('and the same device without it does not', (tester) async {
      await _pumpControls(tester, isTv: false);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      expect(find.byTooltip(l10n.volume), findsNothing);
    });

    // _showCenterGlyph is `!_isTv && !_isDesktop`, so this pair pins the
    // getter, where the volume pair above pins the build-local flag. The two
    // reads are separate and both had to move. One _pumpControls per test:
    // the harness's tear-downs are LIFO around a single channel mock, so a
    // second install in the same test unregisters the first fake's handler.
    testWidgets('a touch device gets the centre glyph', (tester) async {
      await _pumpControls(tester, isTv: false);
      expect(find.byType(PlayerCenterPlayButton), findsOneWidget);
    });

    testWidgets('and the touch centre glyph goes away in Big Picture', (
      tester,
    ) async {
      bigPictureActive.value = true;
      await _pumpControls(tester, isTv: false);
      expect(
        find.byType(PlayerCenterPlayButton),
        findsNothing,
        reason: 'in Big Picture the same device is a ten-foot one, and a '
            'remote steers around a glyph in the middle of the frame',
      );
    });
  });

  group('VlcPlayerControls volume', () {
    // On Android the AudioVolumeUp/Down logical key *is* the hardware rocker,
    // and the embedder gives the framework first refusal:
    // FlutterView.dispatchKeyEvent returns true the moment
    // KeyboardManager.handleEvent says handled, so FrameLayout.dispatchKeyEvent
    // - and with it PhoneWindow's volume fallback and the system HUD - never
    // runs. Claiming the key therefore silences the rocker while the app walks
    // its own libVLC gain. Only a desktop keyboard's volume keys are ours.
    testWidgets('the hardware rocker is handed back on Android and claimed on '
        'desktop', (tester) async {
      // Restored in the body, not in a tear-down: flutter_test verifies the
      // foundation debug variables between the body and the tear-downs.
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      final engine = FakeVlcEngine();
      await _pumpControls(tester, isTv: false, engine: engine);

      final onAndroid = await tester.sendKeyEvent(
        LogicalKeyboardKey.audioVolumeUp,
      );
      await tester.pump();
      expect(
        onAndroid,
        isFalse,
        reason: 'ignored is what redispatches the press to the OS',
      );
      expect(
        _volumes(engine),
        isEmpty,
        reason: 'the phone changes the volume, not the player',
      );

      // The same key on a desktop keyboard is a media key like any other, and
      // there is no OS rail behind it to defer to.
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final onDesktop = await tester.sendKeyEvent(
        LogicalKeyboardKey.audioVolumeUp,
      );
      await tester.pump();
      expect(onDesktop, isTrue);
      expect(_volumes(engine), [105], reason: 'one 5% step up from 100');

      // Let the rail's own clock run out; nothing may be pending at the end.
      await tester.pump(const Duration(seconds: 1));
      await _snapshot(tester, state: 'paused');
      debugDefaultTargetPlatformOverride = null;
    });

    // The pre-mute level has to be whatever the viewer actually had, however
    // they got there. The rail drag never went through the M branch, so the
    // memory was never written and unmuting jumped to a hardcoded 100.
    testWidgets('M unmutes to the level the rail was dragged to, not 100', (
      tester,
    ) async {
      final engine = FakeVlcEngine();
      await _pumpControls(tester, isTv: false, engine: engine);

      // The right half is the volume rail by default; a drag down lands
      // somewhere under the engine's 100. Where exactly does not matter - that
      // M comes back to exactly there does.
      final rect = tester.getRect(find.byType(VlcPlayerControls));
      await tester.dragFrom(
        Offset(rect.right - 200, rect.center.dy),
        const Offset(0, 400),
      );
      await tester.pump(const Duration(milliseconds: 600));
      final dragged = _volumes(engine).last;
      expect(dragged, greaterThan(0));
      expect(dragged, lessThan(100), reason: 'the drag went down');

      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pump();
      expect(_volumes(engine).last, 0, reason: 'M mutes');

      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pump();
      expect(
        _volumes(engine).last,
        dragged,
        reason: 'unmuting returns to the dragged level, not to 100',
      );

      await tester.pump(const Duration(seconds: 1));
      await _snapshot(tester, state: 'paused');
    });

    // Every route into the player's own gain needed hardware a sofa does not
    // have: the AudioVolume keys are claimed on desktop only, the bare Up and
    // Down arrows are a keyboard idiom that television deliberately spends on
    // revealing the chrome, M is a keyboard key and the rail is a drag. So the
    // one device this app is built for was the one device that could not turn
    // the sound up - and in particular could not reach the 100-200% boost the
    // settings screen offers, which is the half of the range that exists
    // precisely because a television's own amplifier is often not enough.
    testWidgets('the OSD volume picker reaches the boost above 100%', (
      tester,
    ) async {
      final engine = FakeVlcEngine();
      await _pumpControls(tester, engine: engine);

      await tester.tap(find.byTooltip('Volume'));
      await tester.pumpAndSettle();

      final selected = tester.widget<ListTile>(
        find.ancestor(of: find.text('100%'), matching: find.byType(ListTile)),
      );
      expect(selected.selected, isTrue, reason: 'the level in force');
      expect(
        selected.autofocus,
        isTrue,
        reason:
            'the remote opens onto the current level, as the speed sheet '
            'does, so a press lands somewhere meaningful',
      );

      expect(
        find.text('200%'),
        findsOneWidget,
        reason: 'ranged over the max, not clamped to 100',
      );
      await tester.tap(find.text('200%'));
      await tester.pumpAndSettle();

      expect(_volumes(engine), <int>[200]);

      await tester.pump(const Duration(seconds: 1));
      await _snapshot(tester, state: 'paused');
    });

    // Absent, not disabled, on the same rule as the lock, the rotate and the
    // fullscreen buttons: rendered where the device has no other way in. A
    // desktop keyboard owns AudioVolumeUp/Down outright and steps the gain on
    // a bare arrow besides, and touch has the vertical rail. Keeping it off
    // the desktop build also keeps the widest row this bar can lay out - a
    // 960 dp television that also reports a desktop OS, so the fullscreen
    // button is in the row as well - inside its own bounds.
    testWidgets('there is no volume button where a keyboard owns the keys', (
      tester,
    ) async {
      await _pumpControls(tester, isTv: false, desktop: true);
      expect(find.byTooltip('Volume'), findsNothing);
      await _snapshot(tester, state: 'paused');
    });

    testWidgets('and none on touch, where the rail is the affordance', (
      tester,
    ) async {
      await _pumpControls(tester, isTv: false);
      expect(find.byTooltip('Volume'), findsNothing);
      await _snapshot(tester, state: 'paused');
    });
  });

  // A D-pad "OK" is not one key. A Shield remote, an Xbox or PlayStation pad
  // and every Android TV device whose HID layer reports DPAD_CENTER as
  // BUTTON_A all send gameButtonA, and nothing further up the tree rescues a
  // miss: WidgetsApp binds gameButtonA to an ActivateIntent but ships no
  // ActivateAction to answer it, and the chip's Focus sits above its InkWell,
  // so the InkWell's own Actions map is a descendant of the focused node and
  // is never reached. The chip is the one control on a clock - missing the
  // press means missing the intro.
  group('VlcPlayerControls activation keys', () {
    final introSegment = <SkipSegment>[
      SkipSegment(startTime: 0, endTime: 60, type: SkipType.intro),
    ];

    testWidgets('the Skip chip activates on a game controller A', (
      tester,
    ) async {
      final engine = FakeVlcEngine();
      await _pumpControls(tester, engine: engine, skipSegments: introSegment);
      expect(find.byIcon(Icons.fast_forward_rounded), findsOneWidget);

      _skipChipNode(tester).requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(
        LogicalKeyboardKey.gameButtonA,
        // flutter_test resolves a key code per platform, and BUTTON_A is in
        // Android's table - which is the platform that has the controllers.
        platform: 'android',
        physicalKey: PhysicalKeyboardKey.gameButtonA,
      );
      await tester.pump();

      expect(_seeks(engine), <int>[60000]);

      // seekTo arms the controller's 1 s stall watchdog, and flutter_test
      // checks for pending timers before tear-downs run. Past the controller's
      // 250 ms event throttle first, or the paused snapshot that disarms it is
      // coalesced away.
      await tester.pump(const Duration(milliseconds: 400));
      await _snapshot(tester, state: 'paused');
    });

    testWidgets('the Skip chip still activates on Select', (tester) async {
      final engine = FakeVlcEngine();
      await _pumpControls(tester, engine: engine, skipSegments: introSegment);

      _skipChipNode(tester).requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();

      expect(_seeks(engine), <int>[60000]);

      // seekTo arms the controller's 1 s stall watchdog, and flutter_test
      // checks for pending timers before tear-downs run. Past the controller's
      // 250 ms event throttle first, or the paused snapshot that disarms it is
      // coalesced away.
      await tester.pump(const Duration(milliseconds: 400));
      await _snapshot(tester, state: 'paused');
    });
  });
}
