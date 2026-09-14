/// What a screen reader actually receives from the player chrome.
///
/// A tooltip that is set is not a name that is delivered. [Tooltip] annotates
/// with `SemanticsProperties.tooltip` and nothing else, and a tooltip placed
/// above a button sits outside the semantics container the button opens, so
/// the annotation cannot merge down into it: the named node is not tappable
/// and the tappable node is not named. Both engines then skip the named one —
/// Android's `AccessibilityBridge.isImportant()` and iOS's
/// `SemanticsObject.isFocusable` look at label/value/hint/actions and neither
/// looks at a tooltip.
///
/// The assertions below are therefore made against the rendered semantics
/// tree, never against a widget's properties, and they ignore any node with
/// `isMergedIntoParent`, since those are folded into an ancestor before the
/// update reaches the platform.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/widgets/player_control_components.dart'
    show
        PlayerActionButton,
        PlayerBottomBar,
        PlayerCenterPlayButton,
        PlayerIconButton,
        PlayerTopBar;

/// Every node that survives merging, i.e. every node the platform is told
/// about. A node with `isMergedIntoParent` contributes its data to an ancestor
/// and is never sent on its own, so including it would let a nameless
/// tap-owner hide behind a named parent.
List<SemanticsNode> _delivered(SemanticsNode root) {
  final out = <SemanticsNode>[];
  void walk(SemanticsNode n) {
    if (!n.isMergedIntoParent) out.add(n);
    n.visitChildren((c) {
      walk(c);
      return true;
    });
  }

  walk(root);
  return out;
}

/// The root of the live semantics tree, reached by climbing from any node in
/// it rather than through the deprecated `binding.pipelineOwner`.
SemanticsNode _root(WidgetTester tester) {
  SemanticsNode node = tester.getSemantics(find.byType(MaterialApp));
  while (node.parent != null) {
    node = node.parent!;
  }
  return node;
}

bool _hasTap(SemanticsData d) => (d.actions & SemanticsAction.tap.index) != 0;

String _describe(List<SemanticsNode> nodes) => nodes
    .map((n) {
      final d = n.getSemanticsData();
      return 'label="${d.label}" tooltip="${d.tooltip}" '
          'button=${d.flagsCollection.isButton} tap=${_hasTap(d)}';
    })
    .join('\n');

void _noop() {}

/// flutter_test verifies that every [SemanticsHandle] was released *before* it
/// runs `addTearDown` callbacks, so the handle has to be disposed inside the
/// body. `finally` keeps a genuine assertion failure as the only error rather
/// than burying it under "A SemanticsHandle was active at the end of the
/// test".
Future<void> _withSemantics(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  final handle = tester.ensureSemantics();
  // A landscape phone, wide enough that the bottom bar lays every control out
  // rather than wrapping.
  tester.view.physicalSize = const Size(2400, 1080);
  tester.view.devicePixelRatio = 2;
  try {
    await body();
  } finally {
    tester.view.reset();
    handle.dispose();
  }
}

/// The chrome as the player builds it: a top bar with its back button, a
/// bottom bar whose leading group is icon-only [PlayerIconButton]s and whose
/// actions are labelled [PlayerActionButton]s, and the centre disc.
Widget _chrome() {
  return MaterialApp(
    home: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          const Align(
            alignment: Alignment.topCenter,
            child: PlayerTopBar(
              title: 'Arcane',
              subtitle: 'S1 E1',
              onBack: _noop,
            ),
          ),
          Center(
            child: PlayerCenterPlayButton(
              playing: true,
              label: 'Pause',
              onPressed: () {},
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: PlayerBottomBar(
              progressBar: const SizedBox(height: 8),
              leading: [
                PlayerIconButton(
                  icon: Icons.replay_10_rounded,
                  tooltip: 'Rewind 10 seconds',
                  onPressed: () {},
                ),
                PlayerIconButton(
                  icon: Icons.pause_rounded,
                  tooltip: 'Pause',
                  onPressed: () {},
                ),
                PlayerIconButton(
                  icon: Icons.forward_10_rounded,
                  tooltip: 'Forward 10 seconds',
                  onPressed: () {},
                ),
                PlayerIconButton(
                  icon: Icons.lock_outline_rounded,
                  tooltip: 'Lock',
                  onPressed: () {},
                ),
              ],
              actions: [
                PlayerActionButton(
                  icon: Icons.subtitles_outlined,
                  label: 'Subtitles',
                  onTap: () {},
                ),
                PlayerIconButton(
                  icon: Icons.fullscreen_rounded,
                  tooltip: 'Fullscreen',
                  onPressed: () {},
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets('every tappable node in the player chrome carries a name', (
    tester,
  ) async {
    await _withSemantics(tester, () async {
      await tester.pumpWidget(_chrome());

      final tappable = _delivered(
        _root(tester),
      ).where((n) => _hasTap(n.getSemanticsData())).toList();

      // Six PlayerIconButtons (back, rewind, pause, forward, lock,
      // fullscreen), one PlayerActionButton, one centre disc.
      expect(tappable, hasLength(8), reason: _describe(tappable));

      final unnamed = tappable
          .where((n) => n.getSemanticsData().label.isEmpty)
          .toList();
      expect(
        unnamed,
        isEmpty,
        reason:
            'These nodes own the tap but tell a screen reader nothing:\n'
            '${_describe(unnamed)}',
      );
    });
  });

  testWidgets('the node that owns the tap is the node that carries the name', (
    tester,
  ) async {
    await _withSemantics(tester, () async {
      await tester.pumpWidget(_chrome());

      final delivered = _delivered(_root(tester));

      for (final name in const [
        'Back', // MaterialLocalizations.backButtonTooltip, via PlayerTopBar
        'Rewind 10 seconds',
        'Pause',
        'Forward 10 seconds',
        'Lock',
        'Fullscreen',
        'Subtitles',
      ]) {
        final named = delivered
            .where((n) => n.getSemanticsData().label == name)
            .toList();
        // Exactly one node per control, not two.
        expect(
          named,
          hasLength(name == 'Pause' ? 2 : 1), // the centre disc repeats 'Pause'
          reason: 'label "$name" in:\n${_describe(delivered)}',
        );
        for (final n in named) {
          final d = n.getSemanticsData();
          expect(_hasTap(d), isTrue, reason: '"$name" is not activatable');
          expect(
            d.flagsCollection.isButton,
            isTrue,
            reason: '"$name" is not announced as a button',
          );
        }
      }
    });
  });

  testWidgets('no player control leaves a named node that cannot be pressed', (
    tester,
  ) async {
    await _withSemantics(tester, () async {
      await tester.pumpWidget(_chrome());

      // A delivered node holding a tooltip with no way to act on it and not
      // flagged as a button is skipped entirely by both engines. Material's
      // own IconButton never produces one.
      final inertNamed = _delivered(_root(tester)).where((n) {
        final d = n.getSemanticsData();
        // The button flag is part of the test: a disabled control
        // legitimately has a name and no tap, and is still announced
        // correctly.
        return d.tooltip.isNotEmpty &&
            !_hasTap(d) &&
            !d.flagsCollection.isButton;
      }).toList();
      expect(inertNamed, isEmpty, reason: _describe(inertNamed));
    });
  });

  testWidgets('the chrome meets the labelled-tap-target guideline', (
    tester,
  ) async {
    await _withSemantics(tester, () async {
      await tester.pumpWidget(_chrome());
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    });
  });

  testWidgets('a disabled control is still named', (tester) async {
    await _withSemantics(tester, () async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: PlayerIconButton(
                icon: Icons.skip_next_rounded,
                tooltip: 'Next episode',
                // No handler: the last episode. It is still on screen, so a
                // reader must still be able to name it.
                onPressed: null,
              ),
            ),
          ),
        ),
      );

      final named = _delivered(
        _root(tester),
      ).where((n) => n.getSemanticsData().label == 'Next episode').toList();
      expect(named, hasLength(1));
      expect(named.single.getSemanticsData().flagsCollection.isButton, isTrue);
    });
  });
}
