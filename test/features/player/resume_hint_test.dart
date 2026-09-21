import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/vlc/resume_hint.dart';
import 'package:skystream/features/player/presentation/widgets/hotstar_player_style.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// Hosts the hint as an overlay layer, with one focusable neighbour standing in
/// for the player chrome so focus has somewhere to go.
Widget _host(Widget child) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          child,
          Align(
            alignment: Alignment.topLeft,
            child: TextButton(onPressed: () {}, child: const Text('chrome')),
          ),
        ],
      ),
    ),
  );
}

/// Unmounts the tree so a pending expiry timer does not outlive the test.
Future<void> _teardown(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox.shrink());

String? get _focusLabel => FocusManager.instance.primaryFocus?.debugLabel;

/// Focuses a control by its node label, so the test does not depend on
/// traversal order to get the remote onto the hint in the first place.
///
/// Resolved through the focus tree rather than `Focus.of` a descendant
/// context: [InkWell] wraps its child in a [Focus] of its own, and the hint
/// deliberately leaves that one unfocusable.
void _focusByLabel(String label) {
  FocusManager.instance.rootScope.descendants
      .firstWhere((node) => node.debugLabel == label)
      .requestFocus();
}

void main() {
  group('ResumeHint', () {
    testWidgets('shows where playback was resumed from', (tester) async {
      await tester.pumpWidget(
        _host(
          ResumeHint(
            position: const Duration(minutes: 42, seconds: 15),
            onStartOver: () {},
            onDismissed: () {},
          ),
        ),
      );

      expect(find.text('Start Over'), findsOneWidget);
      expect(find.text('Paused at 42:15'), findsOneWidget);

      await _teardown(tester);
    });

    testWidgets('shows hours only when there are hours', (tester) async {
      await tester.pumpWidget(
        _host(
          ResumeHint(
            position: const Duration(hours: 1, minutes: 4, seconds: 3),
            onStartOver: () {},
            onDismissed: () {},
          ),
        ),
      );

      expect(find.text('Paused at 1:04:03'), findsOneWidget);

      await _teardown(tester);
    });

    testWidgets('goes away on its own without touching playback', (
      tester,
    ) async {
      var startedOver = 0;
      var dismissed = 0;

      await tester.pumpWidget(
        _host(
          ResumeHint(
            position: const Duration(minutes: 42, seconds: 15),
            visibleFor: const Duration(seconds: 6),
            onStartOver: () => startedOver++,
            onDismissed: () => dismissed++,
          ),
        ),
      );

      await tester.pump(const Duration(seconds: 5));
      expect(dismissed, 0);

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(dismissed, 1);
      expect(
        startedOver,
        0,
        reason: 'expiry must resume silently, unlike the old prompt whose '
            'timeout threw the position away',
      );

      await _teardown(tester);
    });

    testWidgets('Start Over is one press and settles the hint', (tester) async {
      var startedOver = 0;
      var dismissed = 0;

      await tester.pumpWidget(
        _host(
          ResumeHint(
            position: const Duration(minutes: 42, seconds: 15),
            onStartOver: () => startedOver++,
            onDismissed: () => dismissed++,
          ),
        ),
      );

      await tester.tap(find.text('Start Over'));
      expect(startedOver, 1);

      await tester.pumpAndSettle();
      expect(dismissed, 1);

      // A second press lands on a hint that is already gone.
      await tester.pump(const Duration(seconds: 30));
      expect(startedOver, 1);
      expect(dismissed, 1);

      await _teardown(tester);
    });

    testWidgets('dismiss removes the hint without restarting', (tester) async {
      var startedOver = 0;
      var dismissed = 0;

      await tester.pumpWidget(
        _host(
          ResumeHint(
            position: const Duration(minutes: 42, seconds: 15),
            onStartOver: () => startedOver++,
            onDismissed: () => dismissed++,
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(dismissed, 1);
      expect(startedOver, 0);

      await _teardown(tester);
    });

    testWidgets('does not expire out from under the remote', (tester) async {
      var dismissed = 0;

      await tester.pumpWidget(
        _host(
          ResumeHint(
            position: const Duration(minutes: 42, seconds: 15),
            visibleFor: const Duration(seconds: 6),
            isTv: true,
            onStartOver: () {},
            onDismissed: () => dismissed++,
          ),
        ),
      );

      _focusByLabel(kStartOverFocusLabel);
      await tester.pump();
      expect(_focusLabel, kStartOverFocusLabel);

      await tester.pump(const Duration(seconds: 30));
      expect(
        dismissed,
        0,
        reason: 'vanishing while focused would drop focus into nothing',
      );
      expect(find.text('Start Over'), findsOneWidget);

      // Focus leaves for the chrome: the clock starts again.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(dismissed, 1);

      await _teardown(tester);
    });

    // The hint floats over the video with nothing between it and the bottom
    // bar, so the only thing keeping it off the scrubber is the number it is
    // anchored by - and that number has to be the same one on every screen.
    //
    // It was not. A second branch, `compact ? 60.0`, was taken whenever the
    // shortest side came in under 600 dp, which is a phone in landscape, a
    // small desktop window *and* every 960x540 television. The bar is 102 to
    // 137 dp tall, so on each of those the hint was anchored inside it and
    // came up over the scrubber and the transport buttons.
    for (final (String device, bool isTv, Size size, double ratio)
        in <(String, bool, Size, double)>[
          ('a television', true, const Size(1920, 1080), 2.0),
          ('a desktop window', false, const Size(1280, 720), 1.0),
          ('a narrow desktop window', false, const Size(440, 330), 1.0),
          ('a handset in landscape', false, const Size(844, 390), 1.0),
        ]) {
      testWidgets('on $device it clears the whole bottom bar', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = ratio;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          _host(
            ResumeHint(
              position: const Duration(minutes: 42, seconds: 15),
              isTv: isTv,
              onStartOver: () {},
              onDismissed: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();

        final hint = tester.getRect(find.byType(ResumeHint));
        final content = tester.getRect(
          find.descendant(
            of: find.byType(ResumeHint),
            matching: find.byType(FadeTransition),
          ),
        );
        expect(
          hint.bottom - content.bottom,
          greaterThanOrEqualTo(
            HotstarPlayerStyle.bottomChromeHeightFor(isTv: isTv),
          ),
          reason:
              'the hint has to sit above the whole bottom bar, and '
              'controls_focus_test holds the bar inside that same token',
        );
        // And the same vertical line the bar's left end answers to. Not the
        // bare edge inset: the track and the first control are both held an
        // optical amount further in, and a hint flush to the chrome's padding
        // sits visibly outside the column everything else is in.
        expect(
          content.left - hint.left,
          HotstarPlayerStyle.leadingLineOf(isTv: isTv),
          reason: 'the hint starts where the track starts',
        );

        await _teardown(tester);
      });
    }

    testWidgets('D-pad reaches both controls and activates them', (
      tester,
    ) async {
      var startedOver = 0;
      var dismissed = 0;

      await tester.pumpWidget(
        _host(
          ResumeHint(
            position: const Duration(minutes: 42, seconds: 15),
            isTv: true,
            onStartOver: () => startedOver++,
            onDismissed: () => dismissed++,
          ),
        ),
      );

      _focusByLabel(kStartOverFocusLabel);
      await tester.pump();
      expect(_focusLabel, kStartOverFocusLabel);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_focusLabel, kResumeDismissFocusLabel);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(_focusLabel, kStartOverFocusLabel);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(startedOver, 1);

      await tester.pumpAndSettle();
      expect(dismissed, 1);

      await _teardown(tester);
    });

    // A remote's Select is not the only key that means "press this". Every
    // Android TV device whose HID layer reports DPAD_CENTER as BUTTON_A, and
    // every game controller, sends gameButtonA instead - and nothing above
    // rescues it: WidgetsApp binds gameButtonA to an ActivateIntent but ships
    // no ActivateAction, and the hint's Focus sits above its InkWell, so the
    // InkWell's own Actions map is a descendant of the focused node.
    testWidgets('Start Over answers a game controller A', (tester) async {
      var startedOver = 0;
      var dismissed = 0;

      await tester.pumpWidget(
        _host(
          ResumeHint(
            position: const Duration(minutes: 42, seconds: 15),
            isTv: true,
            onStartOver: () => startedOver++,
            onDismissed: () => dismissed++,
          ),
        ),
      );

      _focusByLabel(kStartOverFocusLabel);
      await tester.pump();
      expect(_focusLabel, kStartOverFocusLabel);

      await tester.sendKeyEvent(
        LogicalKeyboardKey.gameButtonA,
        // flutter_test resolves a key code per platform, and BUTTON_A is in
        // Android's table - which is the platform that has the controllers.
        platform: 'android',
        physicalKey: PhysicalKeyboardKey.gameButtonA,
      );
      expect(startedOver, 1);

      await tester.pumpAndSettle();
      expect(dismissed, 1);

      await _teardown(tester);
    });

    testWidgets('Back while focused inside the hint dismisses it', (
      tester,
    ) async {
      var startedOver = 0;
      var dismissed = 0;

      await tester.pumpWidget(
        _host(
          ResumeHint(
            position: const Duration(minutes: 42, seconds: 15),
            isTv: true,
            onStartOver: () => startedOver++,
            onDismissed: () => dismissed++,
          ),
        ),
      );

      _focusByLabel(kStartOverFocusLabel);
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(dismissed, 1);
      expect(startedOver, 0);

      await _teardown(tester);
    });
  });
}
