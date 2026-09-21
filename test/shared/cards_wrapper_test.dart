import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/shared/focus/app_focus.dart';
import 'package:skystream/shared/widgets/cards_wrapper.dart';
import 'package:skystream/shared/widgets/focusable_item.dart';

/// A deliberately loud accent so a colour assertion cannot pass by accident.
///
/// It is here to prove a NEGATIVE now: the focus affordance is neutral, so the
/// accent must not appear in it. What a focused card wears is the Netflix and
/// Prime Video convention - a little scale, a thin neutral border and a
/// shadow - and [_ring] is the colour that border is drawn in.
const Color _accent = Color(0xFF3EA6FF);

/// The ring colour the affordance resolves to under [_host]'s scheme:
/// `ColorScheme.dark().onSurface`, which is white.
const Color _ring = Colors.white;

const Size _cardSize = Size(100, 60);
const Key _childKey = Key('card-child');

/// Gives the card TIGHT constraints, the way a rail with an `itemExtent` does.
/// It has to be tight for the measurement to mean anything: a loose child would
/// keep its own size and simply push the border outwards, hiding the shrink an
/// inside stroke causes in the real layout.
Widget _host(Widget card) {
  return MaterialApp(
    theme: ThemeData.from(
      colorScheme: const ColorScheme.dark(primary: _accent),
    ),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: _cardSize.width,
          height: _cardSize.height,
          child: card,
        ),
      ),
    ),
  );
}

/// Stands in for the artwork: fills whatever the wrapper leaves it.
Widget _plainChild() => const SizedBox.expand(key: _childKey);

/// The single [Container] `CardsWrapper` wraps its child in.
Container _cardContainer(WidgetTester tester) => tester.widget<Container>(
  find.descendant(
    of: find.byType(CardsWrapper),
    matching: find.byType(Container),
  ),
);

void main() {
  setUp(() {
    // Focus highlights only exist in "traditional" mode — a D-pad, a keyboard
    // or a pointer. Default in a widget test is `automatic`, which resolves to
    // `touch` on Android and would suppress the affordance entirely.
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  });

  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  group('CardsWrapper focus affordance', () {
    testWidgets('D-pad focus does not shrink the artwork', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);

      await tester.pumpWidget(
        _host(
          CardsWrapper(focusNode: node, onTap: () {}, child: _plainChild()),
        ),
      );

      final Size unfocused = tester.getSize(find.byKey(_childKey));

      node.requestFocus();
      await tester.pumpAndSettle();
      expect(node.hasFocus, isTrue);

      // LAYOUT size, not the painted rect: a focused card is scaled, and a
      // transform moves what is painted without changing what was laid out.
      // The claim here is about the border - an inside stroke would take
      // `2 * width` off the artwork, and this one takes nothing.
      expect(tester.getSize(find.byKey(_childKey)), unfocused);
      expect(unfocused, _cardSize);
    });

    testWidgets('and grows the card, the way a ten-foot rail does', (
      tester,
    ) async {
      final node = FocusNode();
      addTearDown(node.dispose);

      await tester.pumpWidget(
        _host(
          CardsWrapper(focusNode: node, onTap: () {}, child: _plainChild()),
        ),
      );
      final Rect unfocused = tester.getRect(find.byKey(_childKey));

      node.requestFocus();
      await tester.pumpAndSettle();

      // The scale used to be suppressed for a D-pad specifically, which left
      // the one input that cannot point at anything with the weakest cue on
      // offer. A focused card is scrolled to the middle of its rail, so there
      // is no edge for it to overflow.
      final Rect focused = tester.getRect(find.byKey(_childKey));
      expect(focused.width, greaterThan(unfocused.width));
      expect(focused.center, offsetMoreOrLessEquals(unfocused.center));
    });

    testWidgets('the focus ring is painted entirely outside the card', (
      tester,
    ) async {
      final node = FocusNode();
      addTearDown(node.dispose);

      await tester.pumpWidget(
        _host(
          CardsWrapper(focusNode: node, onTap: () {}, child: _plainChild()),
        ),
      );
      node.requestFocus();
      await tester.pumpAndSettle();

      final Container card = _cardContainer(tester);
      expect(
        card.foregroundDecoration,
        isA<BoxDecoration>(),
        reason: 'the ring must be a FOREGROUND decoration so it paints over '
            'the artwork rather than behind it',
      );
      final BoxDecoration ring = card.foregroundDecoration! as BoxDecoration;
      expect(ring.border, isA<Border>(), reason: 'focused card must draw a ring');
      final BorderSide side = (ring.border! as Border).top;

      expect(side.strokeAlign, BorderSide.strokeAlignOutside);
      expect(side.width, CardFocusAffordance.ringWidth);
      expect(
        side.color,
        _ring,
        reason: 'a focus border is neutral; the accent belongs to selection',
      );
      expect(side.color, isNot(_accent));
      // An outside stroke contributes no padding, which is what keeps the
      // child at exactly its unfocused size.
      expect(ring.padding, EdgeInsets.zero);

      // Geometry, measured off the recorded canvas: the ring's inner edge is
      // the card's own rounded rect and its outer edge is that rect inflated
      // by the full stroke width — i.e. no part of it overlaps the artwork.
      final RRect cardRRect = BorderRadius.circular(
        12,
      ).toRRect(Offset.zero & _cardSize);
      expect(
        find.descendant(
          of: find.byType(CardsWrapper),
          matching: find.byType(DecoratedBox),
        ).first,
        paints
          // 1. the shadow, behind the child. `debugDisableShadows` strips the
          //    blur's mask filter, so it lands as a plain rrect.
          ..rrect(rrect: cardRRect, color: AppFocus.shadows(focused: true)!.single.color)
          // 2. the ring: inner edge == the card, outer edge == the card
          //    inflated by the full stroke, so it never covers artwork. And
          //    nothing between the two - the accent wash that used to be
          //    painted over the poster is gone.
          ..drrect(
            outer: cardRRect.inflate(CardFocusAffordance.ringWidth),
            inner: cardRRect,
            color: _ring,
          ),
      );
    });

    testWidgets('nothing is painted over the artwork, and the lift is black', (
      tester,
    ) async {
      final node = FocusNode();
      addTearDown(node.dispose);

      await tester.pumpWidget(
        _host(
          CardsWrapper(focusNode: node, onTap: () {}, child: _plainChild()),
        ),
      );
      node.requestFocus();
      await tester.pumpAndSettle();

      final Container card = _cardContainer(tester);
      expect(card.foregroundDecoration, isA<BoxDecoration>());

      // The foreground layer carries the border and NOTHING else. An 18 %
      // accent wash used to live here, on top of the poster, which recoloured
      // the artwork the border is meant to be pointing at.
      final BoxDecoration ring = card.foregroundDecoration! as BoxDecoration;
      expect(ring.color, isNull);
      expect(ring.boxShadow, isNull);

      // The lift sits in the BACKGROUND decoration so it only reads outside
      // the card, and it is a plain shadow rather than an accent glow.
      final BoxDecoration glow = card.decoration! as BoxDecoration;
      expect(glow.boxShadow, hasLength(1));
      expect(glow.boxShadow!.single.color, AppFocus.shadows(focused: true)!.single.color);
      expect(glow.boxShadow!.single.offset, Offset.zero);
    });

    testWidgets('the ring follows a caller-supplied borderRadius', (
      tester,
    ) async {
      final node = FocusNode();
      addTearDown(node.dispose);

      await tester.pumpWidget(
        _host(
          CardsWrapper(
            focusNode: node,
            onTap: () {},
            borderRadius: BorderRadius.circular(50),
            child: _plainChild(),
          ),
        ),
      );
      node.requestFocus();
      await tester.pumpAndSettle();

      final Container card = _cardContainer(tester);
      expect(card.foregroundDecoration, isA<BoxDecoration>());
      final BoxDecoration ring = card.foregroundDecoration! as BoxDecoration;
      expect(ring.borderRadius, BorderRadius.circular(50));

      final RRect cardRRect = BorderRadius.circular(
        50,
      ).toRRect(Offset.zero & _cardSize);
      expect(
        find.descendant(
          of: find.byType(CardsWrapper),
          matching: find.byType(DecoratedBox),
        ).first,
        paints
          // The shadow: flutter_test's `debugDisableShadows` strips the
          // blur's mask filter, so it lands as a plain rrect.
          ..rrect(rrect: cardRRect)
          ..drrect(
            outer: cardRRect.inflate(CardFocusAffordance.ringWidth),
            inner: cardRRect,
          ),
      );
    });

    testWidgets('no ring and no lift in touch mode', (tester) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTouch;
      final node = FocusNode();
      addTearDown(node.dispose);

      await tester.pumpWidget(
        _host(
          CardsWrapper(focusNode: node, onTap: () {}, child: _plainChild()),
        ),
      );
      node.requestFocus();
      await tester.pumpAndSettle();

      final Container card = _cardContainer(tester);
      expect((card.foregroundDecoration! as BoxDecoration).border, isNull);
      expect((card.foregroundDecoration! as BoxDecoration).color, isNull);
      expect((card.decoration! as BoxDecoration).boxShadow, isNull);
    });

    testWidgets('focus change never re-inflates the card subtree', (
      tester,
    ) async {
      final node = FocusNode();
      addTearDown(node.dispose);

      await tester.pumpWidget(
        _host(
          CardsWrapper(
            focusNode: node,
            onTap: () {},
            child: const _SubtreeProbe(),
          ),
        ),
      );
      final State<_SubtreeProbe> before = tester.state(
        find.byType(_SubtreeProbe),
      );

      node.requestFocus();
      await tester.pumpAndSettle();
      node.unfocus();
      await tester.pumpAndSettle();

      // Both decorations are non-null in every state, so Container keeps the
      // same two DecoratedBoxes and the child element is reused. If either
      // decoration became null when unfocused, the whole subtree — including
      // the network image — would be thrown away on every focus change.
      expect(identical(tester.state(find.byType(_SubtreeProbe)), before), true);
    });

    testWidgets('onFocusChange reports focus gained and lost', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      final List<bool> events = <bool>[];

      await tester.pumpWidget(
        _host(
          CardsWrapper(
            focusNode: node,
            onTap: () {},
            onFocusChange: events.add,
            child: _plainChild(),
          ),
        ),
      );
      expect(events, isEmpty);

      node.requestFocus();
      await tester.pumpAndSettle();
      expect(events, <bool>[true]);

      node.unfocus();
      await tester.pumpAndSettle();
      expect(events, <bool>[true, false]);
    });
  });

  group('FocusableItem', () {
    testWidgets('draws the same ring and lift as CardsWrapper', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(FocusableItem(onTap: () {}, child: _plainChild())),
      );

      final Size unfocused = tester.getSize(find.byKey(_childKey));

      final FocusNode node = Focus.of(
        tester.element(find.byType(GestureDetector).first),
      );
      node.requestFocus();
      await tester.pumpAndSettle();

      final Container card = tester.widget<Container>(
        find.descendant(
          of: find.byType(FocusableItem),
          matching: find.byType(Container),
        ),
      );
      expect(card.foregroundDecoration, isA<BoxDecoration>());
      final BoxDecoration ring = card.foregroundDecoration! as BoxDecoration;
      expect(
        (ring.border! as Border).top.strokeAlign,
        BorderSide.strokeAlignOutside,
      );
      expect((ring.border! as Border).top.width, CardFocusAffordance.ringWidth);
      expect((ring.border! as Border).top.color, _ring);
      expect(ring.color, isNull);
      expect((card.decoration! as BoxDecoration).boxShadow, hasLength(1));

      // Same consequence as on a card: the child's layout is untouched.
      expect(tester.getSize(find.byKey(_childKey)), unfocused);
    });
  });
}

class _SubtreeProbe extends StatefulWidget {
  const _SubtreeProbe();

  @override
  State<_SubtreeProbe> createState() => _SubtreeProbeState();
}

class _SubtreeProbeState extends State<_SubtreeProbe> {
  @override
  Widget build(BuildContext context) => _plainChild();
}
