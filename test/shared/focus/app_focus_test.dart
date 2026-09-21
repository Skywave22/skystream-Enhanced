import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/shared/focus/app_focus.dart';
import 'package:skystream/shared/widgets/custom_widgets.dart';

/// The rule this file holds: a focus indicator belongs to the person driving
/// the app *without* a pointer.
///
/// It is the web's `:focus-visible`, and it is not the same thing as "this
/// node has focus". A button keeps focus after a mouse click and after an
/// autofocus; drawing a ring in either case leaves a mark on screen that the
/// viewer did not ask for and cannot clear - which is the complaint the whole
/// module was written to answer, on a desktop window in particular, where
/// Flutter's own [FocusManager.highlightMode] calls a mouse "traditional" and
/// so cannot tell the two apart.
void main() {
  /// Reads the published answer from inside the scope.
  Future<bool> pumpProbe(WidgetTester tester, {bool withScope = true}) async {
    late bool visible;
    final probe = Builder(
      builder: (context) {
        visible = FocusVisibility.of(context);
        return const SizedBox.expand();
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: withScope ? FocusVisibilityScope(child: probe) : probe,
      ),
    );
    return visible;
  }

  /// Re-reads after an interaction, which needs a frame to land.
  Future<bool> reread(WidgetTester tester) async {
    await tester.pump();
    final element = tester.element(find.byType(SizedBox));
    return FocusVisibility.of(element);
  }

  group('FocusVisibility', () {
    testWidgets('starts hidden: nothing has been driven yet', (tester) async {
      expect(await pumpProbe(tester), isFalse);
    });

    testWidgets('a key press turns it on', (tester) async {
      await pumpProbe(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(await reread(tester), isTrue);
    });

    testWidgets('and a pointer going down turns it back off', (tester) async {
      await pumpProbe(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(await reread(tester), isTrue);

      await tester.tapAt(const Offset(10, 10));
      expect(await reread(tester), isFalse);
    });

    testWidgets('a mouse moving over the window does not turn it off', (
      tester,
    ) async {
      // The distinction browsers draw, and the one that matters on a desktop:
      // reaching for the mouse is not the same as using it. A ring that
      // vanished on the first stray pixel of motion would flicker for anyone
      // navigating by keyboard with a hand still on the mouse.
      await pumpProbe(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      expect(await reread(tester), isTrue);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(const Offset(50, 50));
      expect(await reread(tester), isTrue);
    });

    testWidgets('nor does a scroll wheel', (tester) async {
      await pumpProbe(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      expect(await reread(tester), isTrue);

      final scroll = TestPointer(1, PointerDeviceKind.mouse);
      scroll.hover(const Offset(20, 20));
      await tester.sendEventToBinding(scroll.scroll(const Offset(0, 60)));
      expect(await reread(tester), isTrue);
    });

    testWidgets('without a scope it falls back to the highlight mode', (
      tester,
    ) async {
      // A test that pumps one widget on its own never builds the root, and
      // must still behave the way Material's built-in highlights do.
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(() {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic;
      });
      expect(await pumpProbe(tester, withScope: false), isTrue);

      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTouch;
      expect(await pumpProbe(tester, withScope: false), isFalse);
    });

    testWidgets("it also drives Flutter's own highlight mode", (tester) async {
      // Otherwise the app runs two rules at once: this file's ring around a
      // focused button and, under it, an [InkWell] that stayed dark because
      // the framework disagreed about whether anyone was using a remote.
      //
      // The framework's own detection is the less trustworthy of the two on a
      // television: it discards any Android key event whose device id is -1 as
      // a soft-keyboard press, which is what an injected event and some
      // network remotes look like, and stays in `touch` for the whole session
      // with every Material focus highlight suppressed.
      addTearDown(() {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic;
      });
      await pumpProbe(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        FocusManager.instance.highlightMode,
        FocusHighlightMode.traditional,
      );

      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      expect(FocusManager.instance.highlightMode, FocusHighlightMode.touch);
    });
  });

  group('the affordance a desktop window actually sees', () {
    /// The details page's Play button: focused the instant the page opens.
    Future<void> pumpAutofocusedButton(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: FocusVisibilityScope(
            child: Scaffold(
              body: Center(
                child: CustomButton(
                  autofocus: true,
                  onPressed: () {},
                  child: const Text('Play'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    BorderSide? sideOf(WidgetTester tester) {
      final button = tester.widget<TextButton>(find.byType(TextButton));
      return button.style?.side?.resolve(const <WidgetState>{});
    }

    testWidgets('an autofocused button is bare until a key arrives', (
      tester,
    ) async {
      // This is the bug, stated: the button holds focus from the first frame,
      // so anything keyed off `hasFocus` alone draws a ring on a window the
      // viewer has only ever clicked in.
      await pumpAutofocusedButton(tester);
      expect(primaryFocus?.hasPrimaryFocus, isTrue);
      expect(sideOf(tester), BorderSide.none);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(sideOf(tester)?.color, ThemeData.dark().colorScheme.onSurface);
      expect(sideOf(tester)?.width, AppFocus.ringWidth);
    });

    testWidgets('and goes bare again on the next click', (tester) async {
      await pumpAutofocusedButton(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(sideOf(tester), isNot(BorderSide.none));

      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(
        sideOf(tester),
        BorderSide.none,
        reason: 'the button still has focus; the viewer has stopped '
            'navigating by key, so the ring is no longer theirs to see',
      );
    });
  });
}
