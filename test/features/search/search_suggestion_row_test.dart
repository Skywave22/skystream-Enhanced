import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/search/presentation/widgets/search_suggestion_row.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

void main() {
  late FocusNode node;

  setUp(() => node = FocusNode());
  tearDown(() => node.dispose());

  Future<void> pumpRow(
    WidgetTester tester, {
    Widget? leading,
    bool withTrailing = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SearchSuggestionRow(
            text: 'Dune',
            icon: Icons.history_rounded,
            leading: leading,
            focusNode: node,
            trailingIcon: withTrailing ? Icons.close_rounded : null,
            onTrailingTap: withTrailing ? () {} : null,
            onTap: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The outermost animated box in the row, which is the one that carries the
  /// highlight.
  Finder rowFill() => find
      .descendant(
        of: find.byType(SearchSuggestionRow),
        matching: find.byType(AnimatedContainer),
      )
      .first;

  group('the highlight', () {
    // The body and the trailing button used to tint their own halves, so a
    // focused row drew a bar that stopped dead before the cross - it read as
    // text selected in a document, not as a row being pointed at.
    testWidgets('covers the whole row, button included', (tester) async {
      await pumpRow(tester);
      node.requestFocus();
      await tester.pumpAndSettle();

      final row = tester.getRect(find.byType(SearchSuggestionRow));
      final fill = tester.getRect(rowFill());

      expect(fill.left, moreOrLessEquals(row.left, epsilon: 0.5));
      expect(fill.right, moreOrLessEquals(row.right, epsilon: 0.5));
      expect(fill.height, moreOrLessEquals(row.height, epsilon: 0.5));
    });

    testWidgets('reaches past the trailing icon', (tester) async {
      await pumpRow(tester);
      node.requestFocus();
      await tester.pumpAndSettle();

      final cross = tester.getRect(find.byIcon(Icons.close_rounded));

      expect(tester.getRect(rowFill()).right, greaterThan(cross.right));
    });

    testWidgets('is absent while the row is neither focused nor hovered', (
      tester,
    ) async {
      await pumpRow(tester);

      final fill = tester.widget<AnimatedContainer>(rowFill());
      final decoration = fill.decoration as BoxDecoration?;

      expect(decoration?.color, Colors.transparent);
    });
  });

  group('the leading inset', () {
    // A poster is its own left edge. The inset that sits well under a 20 dp
    // glyph opens the highlight with a strip of empty colour when the row
    // starts with artwork.
    testWidgets('is tighter for a poster than for a glyph', (tester) async {
      await pumpRow(tester);
      final glyphInset =
          tester.getRect(find.byIcon(Icons.history_rounded)).left -
          tester.getRect(find.byType(SearchSuggestionRow)).left;

      await pumpRow(
        tester,
        leading: const SizedBox(key: ValueKey('poster'), width: 52, height: 76),
      );
      final posterInset =
          tester.getRect(find.byKey(const ValueKey('poster'))).left -
          tester.getRect(find.byType(SearchSuggestionRow)).left;

      expect(posterInset, lessThan(glyphInset));
    });

    testWidgets('puts the poster where the glyph would have been', (
      tester,
    ) async {
      await pumpRow(
        tester,
        leading: const SizedBox(key: ValueKey('poster'), width: 52, height: 76),
      );

      // Still inside the row, not flush against its edge - a poster hard on
      // the highlight's corner would clip against the rounding.
      expect(
        tester.getRect(find.byKey(const ValueKey('poster'))).left -
            tester.getRect(find.byType(SearchSuggestionRow)).left,
        greaterThan(0),
      );
      expect(find.byIcon(Icons.history_rounded), findsNothing);
    });
  });
}
