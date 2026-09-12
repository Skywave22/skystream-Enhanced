import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:skystream/shared/widgets/loading_dialog.dart';

/// Hosts the dialog behind a button so the test drives it the way the app
/// does - `LoadingDialog.show` on a real route, barrier and all - rather than
/// pumping the widget bare, where there is no route to pop and no modal
/// dismiss action to compete with.
class _Host extends StatelessWidget {
  final VoidCallback onCancel;

  const _Host({required this.onCancel});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () => LoadingDialog.show(
          context,
          message: 'Resolving stream',
          onCancel: onCancel,
        ),
        child: const Text('open'),
      ),
    ),
  );
}

/// The indicator inside the dialog animates forever, so `pumpAndSettle` never
/// returns here; every wait in this file is a fixed pump well past the 150 ms
/// dialog transition.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _openDialog(
  WidgetTester tester, {
  required VoidCallback onCancel,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: _Host(onCancel: onCancel),
    ),
  );
  await tester.tap(find.text('open'));
  await _settle(tester);
  expect(find.byType(LoadingDialog), findsOneWidget);
}

void main() {
  // A remote, a keyboard and a gamepad all have to be able to abandon a
  // resolve that is taking too long. The dialog is barrierDismissible:false,
  // so there is no tap-outside escape and the Cancel button was, until this
  // was fixed, the only way out - unreachable without a pointer.
  group('LoadingDialog dismissal', () {
    testWidgets('Back cancels and pops', (tester) async {
      var cancels = 0;
      await _openDialog(tester, onCancel: () => cancels++);

      // What Android delivers for the hardware Back button, and what its
      // generic key layout falls back to for an unconsumed gamepad B.
      await tester.binding.handlePopRoute();
      await _settle(tester);

      expect(cancels, 1, reason: 'Back must run the cancel callback');
      expect(
        find.byType(LoadingDialog),
        findsNothing,
        reason: 'Back must also dismiss the dialog, not just cancel',
      );
    });

    testWidgets('Escape cancels and pops', (tester) async {
      var cancels = 0;
      await _openDialog(tester, onCancel: () => cancels++);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);

      expect(cancels, 1, reason: 'Escape must run the cancel callback');
      expect(
        find.byType(LoadingDialog),
        findsNothing,
        reason: 'Escape must also dismiss the dialog',
      );
    });

    testWidgets('the Cancel button takes focus on open', (tester) async {
      await _openDialog(tester, onCancel: () {});

      final button = tester.widget<TextButton>(find.byType(TextButton).last);
      expect(
        button.focusNode?.hasPrimaryFocus,
        isTrue,
        reason:
            'a D-pad arrives with nothing focused; the one control in the '
            'dialog has to be the one it lands on',
      );
    });

    testWidgets('the Cancel button still cancels and pops', (tester) async {
      var cancels = 0;
      await _openDialog(tester, onCancel: () => cancels++);

      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      await tester.tap(find.text(l10n.cancel));
      await _settle(tester);

      expect(cancels, 1);
      expect(find.byType(LoadingDialog), findsNothing);
    });
  });
}
