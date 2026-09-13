import 'dart:async' show unawaited;
import 'dart:io';
import 'dart:ui' show ErrorCallback, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/logger/app_logger.dart';
import 'package:skystream/core/utils/app_utils.dart';
import 'package:skystream/core/widgets/app_error_boundary.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:talker_flutter/talker_flutter.dart';

/// Before this existed the app had no production error handling at all: no
/// [FlutterError.onError], no [PlatformDispatcher.onError] and no
/// [ErrorWidget.builder]. In a release build that meant a build exception
/// painted the framework's featureless grey rectangle, an async error vanished,
/// and nothing was written anywhere a user could send us.
void main() {
  late Talker sink;
  FlutterExceptionHandler? savedFlutterOnError;
  late ErrorWidgetBuilder savedErrorWidgetBuilder;
  ErrorCallback? savedPlatformOnError;

  setUp(() {
    savedFlutterOnError = FlutterError.onError;
    savedErrorWidgetBuilder = ErrorWidget.builder;
    savedPlatformOnError = PlatformDispatcher.instance.onError;
    debugResetGlobalErrorHandlerInstall();
    sink = createAppTalker(releaseMode: true, output: (String _) {});
  });

  tearDown(() {
    FlutterError.onError = savedFlutterOnError;
    ErrorWidget.builder = savedErrorWidgetBuilder;
    PlatformDispatcher.instance.onError = savedPlatformOnError;
    debugResetGlobalErrorHandlerInstall();
  });

  /// Installs the real handlers and returns the undo.
  ///
  /// The originals have to be captured here rather than in `setUp`, because
  /// `testWidgets` installs its own `FlutterError.onError` after `setUp` has
  /// run: restoring setUp's copy hands the binding a handler it does not own,
  /// and the next framework error trips
  /// `_pendingExceptionDetails != null` and hangs the runner for ten minutes
  /// instead of reporting. For the same reason these tests observe first,
  /// undo, and only then `expect` - flutter_test also asserts that
  /// [ErrorWidget.builder] is back before the body returns.
  VoidCallback installBoundary() {
    final FlutterExceptionHandler? onError = FlutterError.onError;
    final ErrorWidgetBuilder builder = ErrorWidget.builder;
    final ErrorCallback? platformOnError = PlatformDispatcher.instance.onError;
    debugResetGlobalErrorHandlerInstall();
    installGlobalErrorHandlers(logger: sink);
    return () {
      FlutterError.onError = onError;
      ErrorWidget.builder = builder;
      PlatformDispatcher.instance.onError = platformOnError;
      debugResetGlobalErrorHandlerInstall();
    };
  }

  group('installGlobalErrorHandlers', () {
    testWidgets('a build exception paints a recoverable screen, not a blank '
        'rectangle', (WidgetTester tester) async {
      final VoidCallback restore = installBoundary();

      await tester.pumpWidget(_app(const _ThrowsOnBuild()));

      final Object? thrown = tester.takeException();
      final int titles = find.text(_kSomethingWentWrong).evaluate().length;
      final int restarts = find
          .widgetWithText(FilledButton, _kRestartApp)
          .evaluate()
          .length;
      final int details = find.textContaining('boom-in-build').evaluate().length;
      restore();

      expect(thrown, isA<StateError>());
      expect(titles, 1, reason: 'release default is a blank grey rectangle');
      expect(restarts, 1, reason: 'the user needs a way out of it');
      expect(
        details,
        1,
        reason: 'the user needs something quotable in a bug report',
      );
    });

    testWidgets('a framework error reaches the log buffer', (
      WidgetTester tester,
    ) async {
      final VoidCallback restore = installBoundary();

      await tester.pumpWidget(_app(const _ThrowsOnBuild()));
      final Object? thrown = tester.takeException();
      final String recorded = _text(sink);
      restore();

      expect(thrown, isA<StateError>());
      expect(
        recorded,
        contains('boom-in-build'),
        reason: 'release silences debugPrint, so this buffer is all we get',
      );
    });

    test('an uncaught async error is recorded and swallowed', () {
      installGlobalErrorHandlers(logger: sink);

      final ErrorCallback? onError = PlatformDispatcher.instance.onError;
      expect(
        onError,
        isNotNull,
        reason: 'without this an async error vanishes into the zone',
      );

      final bool handled = onError!(
        StateError('async-boom'),
        StackTrace.current,
      );

      expect(handled, isTrue);
      expect(_text(sink), contains('async-boom'));
    });

    test('installing twice does not double-log', () {
      installGlobalErrorHandlers(logger: sink);
      installGlobalErrorHandlers(logger: sink);

      PlatformDispatcher.instance.onError!(
        StateError('once-only'),
        StackTrace.current,
      );

      expect(
        'once-only'.allMatches(_text(sink)).length,
        1,
        reason: 'one entry per error, however often main() is re-entered',
      );
    });
  });

  group('AppErrorView', () {
    testWidgets('renders with no Directionality, Theme or Localizations above '
        'it', (WidgetTester tester) async {
      // The worst case: the exception came from above MaterialApp, so none of
      // the inherited widgets a normal screen relies on exist.
      await tester.pumpWidget(
        AppErrorView(details: _details, showDiagnostics: false),
      );

      expect(tester.takeException(), isNull);
      expect(find.text(_kSomethingWentWrong), findsOneWidget);
      expect(find.widgetWithText(FilledButton, _kRestartApp), findsOneWidget);
    });

    testWidgets('offers no way back when there is nothing to pop', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        AppErrorView(details: _details, showDiagnostics: false),
      );

      expect(find.text(_kGoBack), findsNothing);
    });

    testWidgets('offers a way back out of a pushed route, and it works', (
      WidgetTester tester,
    ) async {
      final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        _app(const Text('under the error'), navigatorKey: nav),
      );

      unawaited(
        nav.currentState!.push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) => Scaffold(
              body: AppErrorView(details: _details, showDiagnostics: false),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(_kGoBack), findsOneWidget);
      await tester.tap(find.text(_kGoBack));
      await tester.pumpAndSettle();

      expect(find.text('under the error'), findsOneWidget);
      expect(find.text(_kSomethingWentWrong), findsNothing);
    });

    testWidgets('the restart action tears the tree down and rebuilds it', (
      WidgetTester tester,
    ) async {
      bool restarted = false;
      AppUtils.setRestartFunction(() => restarted = true);
      addTearDown(() => AppUtils.setRestartFunction(() {}));

      await tester.pumpWidget(
        _app(AppErrorView(details: _details, showDiagnostics: false)),
      );

      await tester.tap(find.widgetWithText(FilledButton, _kRestartApp));
      await tester.pump();
      await tester.pump();

      expect(restarted, isTrue);
    });

    testWidgets('shrinks to fit a slot too small for the full layout', (
      WidgetTester tester,
    ) async {
      // A widget deep in a list can fail, and the replacement inherits its
      // slot - here a 200x24 row. The full layout does not fit in that, and a
      // second overflow painted on top of the first helps nobody.
      await tester.pumpWidget(
        _app(
          Center(
            child: SizedBox(
              width: 200,
              height: 24,
              child: AppErrorView(details: _details, showDiagnostics: false),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.text(_kSomethingWentWrong), findsOneWidget);
    });

    testWidgets('keeps credentials out of the text it shows the user', (
      WidgetTester tester,
    ) async {
      final FlutterErrorDetails leaky = FlutterErrorDetails(
        exception: Exception(
          'GET https://api.themoviedb.org/3/movie/550?api_key=supersecret123 '
          'failed with 401',
        ),
        stack: StackTrace.current,
      );

      await tester.pumpWidget(
        _app(AppErrorView(details: leaky, showDiagnostics: false)),
      );

      expect(find.textContaining('supersecret123'), findsNothing);
      expect(find.textContaining(kRedactedPlaceholder), findsOneWidget);
    });
  });

  test('main() installs the boundary before anything else can throw', () {
    final List<String> lines = File('lib/main.dart').readAsLinesSync();
    final int install = lines.indexWhere(
      (String l) => l.contains('installGlobalErrorHandlers()'),
    );
    final int ensureInit = lines.indexWhere(
      (String l) => l.contains('WidgetsFlutterBinding.ensureInitialized()'),
    );

    expect(
      install,
      isNonNegative,
      reason: 'lib/main.dart must call installGlobalErrorHandlers()',
    );
    expect(
      install,
      lessThan(ensureInit),
      reason: 'a throw during startup has to land somewhere too',
    );
  });
}

/// English, because the boundary falls back to it when [Localizations] is
/// missing and these are the strings a user actually sees.
const String _kSomethingWentWrong = 'Something went wrong. Please try again.';
const String _kRestartApp = 'Restart App';
const String _kGoBack = 'Go Back';

final FlutterErrorDetails _details = FlutterErrorDetails(
  exception: StateError('boom-in-details'),
  stack: StackTrace.current,
);

Widget _app(Widget child, {GlobalKey<NavigatorState>? navigatorKey}) =>
    MaterialApp(
      navigatorKey: navigatorKey,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

String _text(Talker logger) =>
    logger.history.map((TalkerData e) => e.generateTextMessage()).join('\n');

class _ThrowsOnBuild extends StatelessWidget {
  const _ThrowsOnBuild();

  @override
  Widget build(BuildContext context) => throw StateError('boom-in-build');
}
