import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:skystream/core/logger/app_logger.dart';
import 'package:skystream/core/utils/app_utils.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:skystream/l10n/generated/app_localizations_en.dart';
import 'package:talker_flutter/talker_flutter.dart';

/// The app's global error boundary.
///
/// Three holes are plugged here, all of which only bite in a release build:
///
///  * [FlutterError.onError] - a build/layout/paint exception otherwise goes
///    to a console that `main` has silenced.
///  * [PlatformDispatcher.onError] - an uncaught async error otherwise
///    disappears entirely. This is the framework's supported replacement for
///    wrapping `runApp` in `runZonedGuarded`; setting both would be redundant,
///    since a zone handler swallows the error before the dispatcher sees it.
///  * [ErrorWidget.builder] - the default paints an untextured grey rectangle
///    in release, with no text and no way out of it.
///
/// Call once, as early in `main` as possible.
void installGlobalErrorHandlers({Talker? logger}) {
  if (_installed) return;
  _installed = true;

  final Talker sink = logger ?? talker;
  final FlutterExceptionHandler? previousOnError = FlutterError.onError;

  FlutterError.onError = (FlutterErrorDetails details) {
    sink.handle(details.exception, details.stack, _contextOf(details));
    // Keep the debug red screen and, in tests, flutter_test's own error
    // capture. In release the default handler only writes to a console that
    // `main` has already no-oped.
    if (!kReleaseMode) {
      (previousOnError ?? FlutterError.presentError)(details);
    }
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    sink.handle(error, stack, 'Uncaught async error');
    return true;
  };

  ErrorWidget.builder = (FlutterErrorDetails details) =>
      AppErrorView(details: details);
}

bool _installed = false;

/// Lets a test install handlers again after restoring the originals.
@visibleForTesting
void debugResetGlobalErrorHandlerInstall() => _installed = false;

String _contextOf(FlutterErrorDetails details) {
  final String library = details.library ?? 'Flutter framework';
  final String? context = details.context?.toDescription();
  return context == null ? 'Error in $library' : 'Error in $library: $context';
}

/// A one-line, credential-free summary of [details] fit to show a user and to
/// paste into a bug report.
String describeErrorForDisplay(FlutterErrorDetails details) {
  final Object exception = details.exception;
  String text;
  if (exception is FlutterError && exception.diagnostics.isNotEmpty) {
    text = exception.diagnostics.first.toDescription();
  } else {
    text = exception.toString();
  }
  // Cut before redacting: this runs during a build, and the redaction regexes
  // are only cheap on bounded input.
  if (text.length > _rawTextCap) text = text.substring(0, _rawTextCap);
  text = redactSecrets(text).replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.length > 240) text = '${text.substring(0, 239)}…';
  return text;
}

/// How much of an exception or stack trace is worth redacting and showing.
const int _rawTextCap = 2000;

/// Replaces the failing subtree with something a person can act on.
///
/// The hard constraint on this widget is that it is dropped into whatever slot
/// the widget that threw was occupying - which may be a 20 px row in a list, an
/// unbounded column, or the whole window - and it must never itself throw or
/// overflow, because a second exception here recurses through
/// [ErrorWidget.builder]. Hence: no assumption that [Directionality],
/// [MediaQuery] or [Localizations] exist above it, a compact form for slots too
/// small for the full one, and a last-ditch `catch` around the build.
class AppErrorView extends StatelessWidget {
  const AppErrorView({
    super.key,
    required this.details,
    this.showDiagnostics = !kReleaseMode,
  });

  final FlutterErrorDetails details;

  /// Whether to append the full exception text under the summary. Off in
  /// release, where the one-line summary is all a user needs to quote.
  final bool showDiagnostics;

  /// Below either of these the full layout cannot fit, so the compact one is
  /// used instead of overflowing.
  static const double _minFullWidth = 260;
  static const double _minFullHeight = 200;

  @override
  Widget build(BuildContext context) {
    try {
      return _build(context);
    } catch (_) {
      // Never recurse into ErrorWidget.builder from the error widget itself.
      return const ColoredBox(color: Color(0xFF1C1B1F));
    }
  }

  Widget _build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    Widget content = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool tooNarrow =
            constraints.hasBoundedWidth && constraints.maxWidth < _minFullWidth;
        final bool tooShort =
            constraints.hasBoundedHeight &&
            constraints.maxHeight < _minFullHeight;
        if (tooNarrow || tooShort) return _compact(context, constraints, colors);
        return _full(context, constraints, colors);
      },
    );

    content = Material(color: colors.surface, child: content);

    if (MediaQuery.maybeOf(context) == null) {
      content = MediaQuery(data: const MediaQueryData(), child: content);
    }
    return Directionality(
      textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
      child: content,
    );
  }

  /// Slot too small for buttons: say what happened and nothing else.
  ///
  /// [OverflowBox] hands the row an unbounded height so a 20 px slot produces a
  /// clipped row rather than a RenderFlex overflow - which would be a second
  /// error painted over the first.
  Widget _compact(
    BuildContext context,
    BoxConstraints constraints,
    ColorScheme colors,
  ) {
    final AppLocalizations l10n = _localizations(context);
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.center,
        minWidth: 0,
        maxWidth: constraints.hasBoundedWidth ? constraints.maxWidth : 320,
        minHeight: 0,
        maxHeight: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.error_outline, size: 16, color: colors.error),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  l10n.generalError,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: colors.onSurface),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _full(
    BuildContext context,
    BoxConstraints constraints,
    ColorScheme colors,
  ) {
    final AppLocalizations l10n = _localizations(context);
    final NavigatorState? navigator = Navigator.maybeOf(context);
    final bool canPop = navigator?.canPop() ?? false;

    final Column column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Icon(Icons.error_outline, size: 40, color: colors.error),
        const SizedBox(height: 12),
        Text(
          l10n.generalError,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: colors.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          describeErrorForDisplay(details),
          textAlign: TextAlign.center,
          maxLines: showDiagnostics ? 12 : 4,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            height: 1.3,
            color: colors.onSurfaceVariant,
          ),
        ),
        if (showDiagnostics) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            redactSecrets(_head(details.stack?.toString() ?? '')),
            maxLines: 8,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              fontFamily: 'monospace',
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 20),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            if (canPop)
              TextButton(
                onPressed: () => navigator!.maybePop(),
                child: Text(l10n.goBack),
              ),
            FilledButton.icon(
              autofocus: true,
              onPressed: () => unawaited(AppUtils.restartApp(context)),
              icon: const Icon(Icons.restart_alt),
              label: Text(l10n.restartApp),
            ),
          ],
        ),
      ],
    );

    final Widget padded = Padding(
      padding: const EdgeInsets.all(24),
      child: column,
    );

    // A bounded slot scrolls rather than overflows; an unbounded one must not
    // be handed to a scroll view at all.
    return Center(
      child: constraints.hasBoundedHeight
          ? SingleChildScrollView(child: padded)
          : padded,
    );
  }

  static String _head(String value) =>
      value.length <= _rawTextCap ? value : value.substring(0, _rawTextCap);

  /// Falls back to English when the failure happened above [Localizations] -
  /// an unlocalized recovery screen beats a grey rectangle.
  AppLocalizations _localizations(BuildContext context) =>
      AppLocalizations.of(context) ?? AppLocalizationsEn();
}
