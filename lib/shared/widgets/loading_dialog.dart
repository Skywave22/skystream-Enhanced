import 'package:flutter/material.dart';
import 'custom_widgets.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'loading_indicator.dart';

class LoadingDialog extends StatelessWidget {
  final String message;
  final VoidCallback onCancel;

  const LoadingDialog({
    super.key,
    required this.message,
    required this.onCancel,
  });

  /// The single exit. Every route out of this dialog - the button, Back, and
  /// Escape - runs this, so cancellation and dismissal can never come apart.
  void _cancel(BuildContext context) {
    onCancel();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        // Escape, from a desktop keyboard. The route's own dismiss action is
        // gated on `barrierDismissible`, which `show` sets false, so without
        // this nothing above answers Escape and the key is dead. Back is not
        // handled here: it arrives as a route pop, which the PopScope below
        // owns, and taking it twice would cancel twice.
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (_) {
            _cancel(context);
            return null;
          },
        ),
      },
      child: PopScope(
        canPop: false, // Blocked so cancellation runs before the pop.
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          // Android's hardware Back, and a gamepad B - which Android's generic
          // key layout falls back to Back when nothing consumes it.
          _cancel(context);
        },
        child: AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 24),
              const AppLoadingIndicator(),
              const SizedBox(height: 24),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
              ),
            ],
          ),
          actions: [
            CustomButton(
              isPrimary: false,
              // The only control in the dialog, so a D-pad has somewhere to
              // land. It also puts primary focus inside the dialog, which is
              // what lets the Escape action above be found.
              autofocus: true,
              onPressed: () => _cancel(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(AppLocalizations.of(context)!.cancel),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Future<void> show(
    BuildContext context, {
    required String message,
    required VoidCallback onCancel,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => LoadingDialog(message: message, onCancel: onCancel),
    );
  }
}
