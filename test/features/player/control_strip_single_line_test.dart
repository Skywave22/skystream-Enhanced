// DEFECT 3. The bottom-left control cluster rendered on **two lines** on a
// handset instead of one line that scrolls.
//
// [PlayerBottomBar]'s touch branch used to run a [LayoutBuilder] and, below
// `narrowTouchWidth` of inner width, hand the action strip a run of its own
// above the transport row via a [Wrap]. On the commonest Android portrait
// width - 360 dp, so 320 inside the bar's two 20 dp edge insets - the
// transport group (250 dp of pinned buttons) and the strip could not share a
// line, so the [Wrap] took a second run and the bar stood 112 dp tall instead
// of 64. That is the two-line cluster the owner photographed. The strip is
// now one line at every width, right-anchored, finger-scrolled, with the edge
// hint that says so.
//
// This file measures [PlayerBottomBar] directly rather than driving
// [VlcPlayerControls], because the controls pick `isTouch` off
// `Platform.isAndroid || Platform.isIOS`, which is false on every test host:
// a test that went through them would silently measure the desktop bar and
// pin nothing about a phone. The affected platforms are the touch ones -
// Android phone/tablet (chrome composited over the AndroidView platform view)
// and iOS (over the NV12 texture) - and the non-touch branch that television,
// macOS, Windows and Linux take is asserted here too, unchanged, because it
// is the same [Row].
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/widgets/hotstar_player_style.dart';
import 'package:skystream/features/player/presentation/widgets/player_control_components.dart'
    show PlayerActionStrip, PlayerBottomBar, PlayerIconButton;
import 'package:skystream/l10n/generated/app_localizations.dart';

/// What five pinned transport buttons - seek back, play/pause, seek forward,
/// lock, next - measure on a handset. Asserted against the real control row
/// in `controls_focus_test.dart`; here it is the load that squeezes the strip.
const double _kTransportWidth = 250;

/// A torrent series renders this many utilities: sources, episodes, files,
/// audio, subtitles, speed, volume, rotate, resize, PiP.
const int _kActions = 10;

void main() {
  /// A bar of [actions] utilities in a [width] dp viewport. The leading group
  /// is a single spacer of the transport row's measured width: the only thing
  /// this layout cares about is how much of the line it takes.
  Widget host({
    required double width,
    required bool isTv,
    required bool isTouch,
    int actions = _kActions,
  }) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            width: width,
            child: PlayerBottomBar(
              isTv: isTv,
              isTouch: isTouch,
              progressBar: const SizedBox(height: 8),
              leading: const [SizedBox(width: _kTransportWidth, height: 48)],
              actions: <Widget>[
                for (int i = 0; i < actions; i++)
                  PlayerIconButton(
                    icon: Icons.circle,
                    tooltip: 'a$i',
                    isTv: isTv,
                    onPressed: () {},
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> pumpBar(
    WidgetTester tester, {
    required Size size,
    required bool isTv,
    required bool isTouch,
    int actions = _kActions,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(width: size.width, isTv: isTv, isTouch: isTouch, actions: actions),
    );
    // The strip reports its scroll metrics in a microtask after layout and
    // shows or hides the edge hint on the frame after that, so an unsettled
    // tree is measured mid-decision.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Every action button's rectangle in screen space.
  List<Rect> actionRects(WidgetTester tester) => find
      .byType(PlayerIconButton)
      .evaluate()
      .map((e) => e.renderObject! as RenderBox)
      .map((b) => b.localToGlobal(Offset.zero) & b.size)
      .toList();

  /// The whole control row: the utilities plus the pinned transport group.
  /// Both, always - the old two-run bar kept the ten utilities on one run
  /// between themselves and put the transport on the other, so a count that
  /// left the transport out would have called it one line.
  List<Rect> rowRects(WidgetTester tester) => <Rect>[
    ...actionRects(tester),
    tester.getRect(
      find.byWidgetPredicate(
        (w) => w is SizedBox && w.width == _kTransportWidth,
      ),
    ),
  ];

  /// How many horizontal runs those buttons occupy. Vertical centres within
  /// half a button of each other are the same run; a second entry here is the
  /// defect.
  int runCount(List<Rect> rects) {
    final List<double> centres = rects.map((r) => r.center.dy).toList()..sort();
    final List<double> runs = <double>[];
    for (final double c in centres) {
      if (runs.isEmpty || (c - runs.last).abs() > 24) runs.add(c);
    }
    return runs.length;
  }

  group('the touch control strip is one line that scrolls', () {
    // 360x800 is the commonest Android portrait frame and the one the owner
    // reported from. 320 dp inside the edge insets, 250 of it spoken for by
    // the transport group.
    testWidgets('a 360 dp portrait handset keeps every control on one run', (
      tester,
    ) async {
      await pumpBar(
        tester,
        size: const Size(360, 800),
        isTv: false,
        isTouch: true,
      );

      // The transport group is counted as part of the row, and that is the
      // whole trick of this measurement: the old two-run bar put the strip
      // alone on one line and the transport alone on the other, so the ten
      // utilities were *still* on one run between themselves. Counting only
      // them would pin nothing.
      final Rect transport = tester.getRect(
        find.byWidgetPredicate(
          (w) => w is SizedBox && w.width == _kTransportWidth,
        ),
      );
      expect(actionRects(tester), hasLength(_kActions));
      final List<Rect> row = rowRects(tester);
      expect(
        runCount(row),
        1,
        reason:
            'the control row is on ${runCount(row)} runs at '
            '${row.map((r) => r.center.dy).toSet().toList()}; a second run '
            'is the two-line cluster the owner reported',
      );

      final Rect strip = tester.getRect(find.byType(PlayerActionStrip));
      expect(
        strip.center.dy,
        moreOrLessEquals(transport.center.dy, epsilon: 0.5),
        reason:
            'the strip at $strip is on a different line from the transport '
            'group at $transport',
      );
      expect(
        strip.left,
        moreOrLessEquals(transport.right, epsilon: 0.5),
        reason: 'and it starts where the transport group ends, on that line',
      );

      // The height that second run cost: 8 of scrubber, 48 of controls and
      // the bar's own 2+6 of padding is 64. With the strip on its own run it
      // measured 112.
      expect(
        tester.getSize(find.byType(PlayerBottomBar)).height,
        64,
        reason:
            'the bar is chrome over the video - on Android over the '
            'AndroidView platform view itself - and a second run costs the '
            'frame 48 dp',
      );
    });

    testWidgets('and it is honest about what it is hiding, and reachable', (
      tester,
    ) async {
      await pumpBar(
        tester,
        size: const Size(360, 800),
        isTv: false,
        isTouch: true,
      );

      final Rect strip = tester.getRect(find.byType(PlayerActionStrip));
      expect(
        strip.width,
        lessThan(_kActions * 48),
        reason:
            'ten 48 dp buttons do not fit ${strip.width} dp, which is the '
            'whole reason the strip has to say it scrolls',
      );
      expect(
        find.byIcon(Icons.chevron_left_rounded),
        findsOneWidget,
        reason:
            'a right-anchored strip that overflows off the left edge with no '
            'fade and no chevron is a strip nobody knows is there',
      );

      // The promise a one-line strip makes: a fling reaches the buttons the
      // squeeze pushed off the left edge. The first utility is the one that
      // is furthest away.
      expect(find.byTooltip('a0').hitTestable(), findsNothing);
      await tester.drag(find.byType(PlayerActionStrip), const Offset(600, 0));
      await tester.pumpAndSettle();
      expect(
        find.byTooltip('a0').hitTestable(),
        findsOneWidget,
        reason: 'the far end of the strip has to be reachable by finger',
      );
      expect(
        find.byIcon(Icons.chevron_left_rounded),
        findsNothing,
        reason: 'and once there is nothing left to reveal, the hint goes',
      );
      expect(
        runCount(rowRects(tester)),
        1,
        reason: 'scrolling does not reflow the strip either',
      );
    });

    // 844x390 is the landscape frame in the rest of the player tests. It has
    // always fitted one line; the point here is that it costs no more than
    // the portrait one now, which is what the old branch charged 48 dp for.
    testWidgets('an 844x390 landscape handset is the same one run, same '
        'height', (tester) async {
      await pumpBar(
        tester,
        size: const Size(844, 390),
        isTv: false,
        isTouch: true,
      );

      expect(runCount(rowRects(tester)), 1);
      expect(tester.getSize(find.byType(PlayerBottomBar)).height, 64);
      expect(
        tester.getRect(find.byType(PlayerActionStrip)).width,
        greaterThan(400),
        reason: 'the strip takes the whole remainder of the flat row',
      );
      expect(
        find.byIcon(Icons.chevron_left_rounded),
        findsNothing,
        reason: 'nothing is hidden here, so nothing may claim it is',
      );
    });

    // The widest a phone-shaped viewport gets before the old code stopped
    // splitting: one dp under the retired threshold. It used to be the worst
    // case - a bar that reflowed to two runs on a rotation - and now it is
    // the same single line as everything else.
    testWidgets('and a viewport just under the retired narrow threshold does '
        'not reflow', (tester) async {
      const double justUnder =
          PlayerBottomBar.narrowTouchWidth +
          2 * HotstarPlayerStyle.edgeInset -
          1;
      await pumpBar(
        tester,
        size: const Size(justUnder, 800),
        isTv: false,
        isTouch: true,
      );

      expect(runCount(rowRects(tester)), 1);
      expect(tester.getSize(find.byType(PlayerBottomBar)).height, 64);
    });
  });

  // The other branch of the same [Row], which television, macOS, Windows and
  // Linux take. It is deliberately still a [Wrap]: there is no fling off
  // touch, so an overflow has to be laid out rather than scrolled. These
  // guard against "fixing" the handset by flattening the branch that has to
  // grow.
  group('the non-touch action row is unchanged', () {
    for (final (String name, Size size, bool isTv) in <(String, Size, bool)>[
      ('a 960x540 television', const Size(960, 540), true),
      ('a narrow 800x600 desktop window', const Size(800, 600), false),
    ]) {
      testWidgets('$name lays ten utilities on one run', (tester) async {
        await pumpBar(tester, size: size, isTv: isTv, isTouch: false);

        expect(runCount(rowRects(tester)), 1);
        expect(tester.getSize(find.byType(PlayerBottomBar)).height, 64);
        expect(
          find.byType(PlayerActionStrip),
          findsNothing,
          reason: 'the scrolling strip is a touch affordance only',
        );
      });

      testWidgets('$name still wraps upwards when they do not fit', (
        tester,
      ) async {
        await pumpBar(
          tester,
          size: size,
          isTv: isTv,
          isTouch: false,
          actions: 16,
        );

        expect(
          runCount(actionRects(tester)),
          2,
          reason:
              'off touch nothing may be clipped and nothing may be hidden '
              'behind a gesture the device cannot make',
        );
        expect(
          tester.getSize(find.byType(PlayerBottomBar)).height,
          112,
          reason: 'the bar grows upwards by exactly one run',
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
}
