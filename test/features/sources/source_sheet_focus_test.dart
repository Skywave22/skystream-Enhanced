import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/sources/presentation/source_sheet_widgets.dart';

/// The TV model the sources sheets are built around:
///
///   UP / DOWN  moves between source cards
///   LEFT/RIGHT moves inside the focused card, into Play / Download
///
/// The Play / Download row sits at the bottom edge of a card, so from a
/// neighbouring card those buttons clear Flutter's directional filter
/// (`centre.dy <= target.top` going up) and win on distance against the card
/// they belong to. These tests pin the intended behaviour against the real
/// card geometry.
void main() {
  testWidgets('DOWN steps card to card, never onto an action button', (
    tester,
  ) async {
    await tester.pumpWidget(const _Harness());
    await tester.pump();
    expect(_focused(), 'card1');

    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focused(), 'card2');

    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focused(), 'card3');
  });

  testWidgets('UP steps card to card, never onto an action button', (
    tester,
  ) async {
    await tester.pumpWidget(const _Harness(autofocusIndex: 2));
    await tester.pump();
    expect(_focused(), 'card3');

    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focused(), 'card2');

    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focused(), 'card1');
  });

  testWidgets('RIGHT from a focused card reaches that card\'s Play button', (
    tester,
  ) async {
    await tester.pumpWidget(const _Harness(autofocusIndex: 1));
    await tester.pump();
    expect(_focused(), 'card2');

    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focused(), 'play2');

    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focused(), 'download2');

    await _press(tester, LogicalKeyboardKey.arrowLeft);
    expect(_focused(), 'play2');

    await _press(tester, LogicalKeyboardKey.arrowLeft);
    expect(_focused(), 'card2');
  });

  // Each of these starts from a fresh pump: Flutter's directional policy
  // retraces its own history when the direction reverses, which would answer
  // the second press from the record of the first rather than from geometry.
  testWidgets('DOWN from a focused action button lands on the next card', (
    tester,
  ) async {
    await tester.pumpWidget(const _Harness(autofocusIndex: 1));
    await tester.pump();

    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focused(), 'play2');

    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focused(), 'card3');
  });

  testWidgets('UP from a focused action button returns to its own card', (
    tester,
  ) async {
    await tester.pumpWidget(const _Harness(autofocusIndex: 1));
    await tester.pump();

    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focused(), 'play2');

    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focused(), 'card2');
  });

  testWidgets('action buttons keep a 48dp tap target without growing', (
    tester,
  ) async {
    await tester.pumpWidget(const _Harness());
    await tester.pump();

    final Rect play = tester.getRect(find.byKey(const ValueKey('play1')));
    expect(
      play.height,
      lessThan(kMinInteractiveDimension),
      reason: 'the chip must keep painting at its compact size',
    );

    // A press above the chip, inside the 48dp band, still activates it.
    final Offset aboveChip = Offset(
      play.center.dx,
      play.top - (kMinInteractiveDimension - play.height) / 2 + 1,
    );
    await tester.tapAt(aboveChip);
    await tester.pump();
    expect(_tapped, 'play1');
  });

  testWidgets('action chips report a button role', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();

    await tester.pumpWidget(const _Harness());
    await tester.pump();

    expect(
      tester.getSemantics(find.byKey(const ValueKey('play1'))),
      isSemantics(
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        label: 'Play',
      ),
    );
    handle.dispose();
  });

  testWidgets('a disabled action chip reports a disabled button', (
    tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SourceActionSemantics(
              enabled: false,
              child: Text('Download now'),
            ),
          ),
        ),
      ),
    );

    expect(
      tester.getSemantics(find.text('Download now')),
      isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
    );
    handle.dispose();
  });
}

String? _focused() => FocusManager.instance.primaryFocus?.debugLabel;

String? _tapped;

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

class _Harness extends StatelessWidget {
  const _Harness({this.autofocusIndex = 0});

  final int autofocusIndex;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SizedBox(
          width: 420,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
            children: [
              for (int i = 0; i < 3; i++) ...[
                if (i > 0) const SizedBox(height: 6),
                _SourceCard(index: i + 1, autofocus: i == autofocusIndex),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Same shape as `_SourceRow` in both sheets: a text block with the action
/// row pinned to the bottom edge of the card.
///
/// Each card and each chip contributes exactly one focus node. An [InkWell]
/// that can request focus adds a second, unlabelled node with the same rect,
/// and directional traversal then lands on it instead of the card — a stop
/// that paints no focus ring. The sheets have to pass `canRequestFocus: false`
/// for the same reason.
class _SourceCard extends StatefulWidget {
  const _SourceCard({required this.index, required this.autofocus});

  final int index;
  final bool autofocus;

  @override
  State<_SourceCard> createState() => _SourceCardState();
}

class _SourceCardState extends State<_SourceCard> {
  late final FocusNode _cardFocusNode = FocusNode(
    debugLabel: 'card${widget.index}',
  );
  late final FocusNode _playFocusNode = FocusNode(
    debugLabel: 'play${widget.index}',
  );
  late final FocusNode _downloadFocusNode = FocusNode(
    debugLabel: 'download${widget.index}',
  );

  @override
  void dispose() {
    _cardFocusNode.dispose();
    _playFocusNode.dispose();
    _downloadFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Focus(
      focusNode: _cardFocusNode,
      autofocus: widget.autofocus,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.arrowRight) {
          _playFocusNode.requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          canRequestFocus: false,
          onTap: () {},
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white24, width: 1.2),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    SourceTag(
                      text: '1080p',
                      container: cs.primaryContainer,
                      onContainer: cs.onPrimaryContainer,
                    ),
                    const SizedBox(width: 6),
                    SourceTag(
                      text: 'HDR',
                      container: cs.tertiaryContainer,
                      onContainer: cs.onTertiaryContainer,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Provider ${widget.index}',
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 2),
                const Text('some detail line', style: TextStyle(fontSize: 11)),
                const SizedBox(height: 8),
                SourceCardActions(
                  cardFocusNode: _cardFocusNode,
                  child: Row(
                    children: [
                      const Spacer(),
                      _chip(
                        focusNode: _playFocusNode,
                        label: 'Play',
                        icon: Icons.play_arrow_rounded,
                        onLeft: _cardFocusNode,
                        onRight: _downloadFocusNode,
                      ),
                      const SizedBox(width: 8),
                      _chip(
                        focusNode: _downloadFocusNode,
                        label: 'Download now',
                        icon: Icons.download_rounded,
                        onLeft: _playFocusNode,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _chip({
    required FocusNode focusNode,
    required String label,
    required IconData icon,
    FocusNode? onLeft,
    FocusNode? onRight,
  }) {
    return Focus(
      focusNode: focusNode,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
            onLeft != null) {
          onLeft.requestFocus();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
            onRight != null) {
          onRight.requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: SourceActionSemantics(
        enabled: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey<String>(focusNode.debugLabel!),
            canRequestFocus: false,
            onTap: () => _tapped = focusNode.debugLabel,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white24),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 14),
                  const SizedBox(width: 4),
                  Text(label, style: const TextStyle(fontSize: 11)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
