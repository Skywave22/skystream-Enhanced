/// The Settings button on an installed CloudStream extension: it shows when the extension has a screen,
/// opens it in SkyStream's sheet, and applies the changes once the sheet closes.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_engine.dart';
import 'package:skystream/core/cloudstream/cloudstream_models.dart';
import 'package:skystream/core/cloudstream/cloudstream_repository.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/features/cloudstream/presentation/cloudstream_screen.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

const _info = CsPluginInfo(
  internalName: 'Alpha',
  name: 'Alpha',
  url: 'https://repo.test/Alpha.cs3',
  repositoryUrl: 'https://repo.test/repo.json',
);

class _FakeCloudStream extends CloudStreamRepository {
  _FakeCloudStream(this._initial);

  final CloudStreamState _initial;
  final applied = <String>[];

  @override
  CloudStreamState build() => _initial;

  @override
  Future<void> learnSettings() async {}

  @override
  Future<void> applySettings(CsInstalledPlugin plugin) async => applied.add(plugin.info.name);
}

/// An engine host whose extension shows one checkbox, and closes when told to.
class _FakeHost extends CloudStreamEngineHost {
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  bool failing = false;
  final sent = <String>[];
  var opened = 0;

  /// While set, a screen takes until it completes to open, as the engine's does on a device.
  Completer<void>? holdOpen;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Future<int> openSettings(String path, {String? pluginUrl}) async {
    opened++;
    await holdOpen?.future;
    if (failing) throw StateError('Alpha.cs3 showed no settings screen');
    _events.add({
      'event': 'ui',
      'session': 3,
      'plugin': path,
      'windows': [
        {
          'id': 'w1',
          'kind': 'sheet',
          'root': {'id': 1, 'kind': 'checkbox', 'text': 'Second provider', 'checked': true, 'tappable': true},
        },
      ],
    });
    return 3;
  }

  @override
  Future<int> openPopups(String path, {String? pluginUrl}) async {
    _events.add({
      'event': 'ui',
      'session': 4,
      'plugin': path,
      'windows': [
        {
          'id': 'w1',
          'kind': 'dialog',
          'root': {'id': 1, 'kind': 'text', 'text': 'Support us'},
        },
      ],
    });
    return 4;
  }

  @override
  Future<Map<String, dynamic>> uiAction(int session, int node, String action, [Object? value]) async {
    sent.add('$node $action');
    if (action == 'close') _events.add({'event': 'uiClosed', 'session': session, 'reason': 'closed', 'actions': 0});
    return {'done': true};
  }

  final closed = <String>[];

  @override
  Future<void> closeUi(int session, {bool force = false}) async {
    closed.add('$session $force');
    _events.add({'event': 'uiClosed', 'session': session, 'reason': 'closed', 'actions': 0});
  }

  /// The extension's code crashed on the main thread: the engine ended the screen.
  void crash(int session) => _events.add({
    'event': 'uiClosed',
    'session': session,
    'reason': 'error',
    'error': 'NullPointerException: views gone',
  });
}

void main() {
  Future<(_FakeCloudStream, _FakeHost)> boot(
    WidgetTester tester, {
    bool? hasSettings = true,
    Set<String> applying = const {},
    Map<String, List<String>> popups = const {},
  }) async {
    final plugin = CsInstalledPlugin(
      info: _info,
      filePath: '/x/Alpha.cs3',
      providers: const [CsProviderInfo(name: 'Alpha')],
      hasSettings: hasSettings,
    );
    final repository = _FakeCloudStream(
      CloudStreamState(isLoading: false, installed: [plugin], applying: applying, popups: popups),
    );
    final host = _FakeHost();
    await tester.pumpWidget(
      ProviderScope(
        // A new scope each boot: one test boots three times, and a kept scope keeps its first overrides.
        key: UniqueKey(),
        overrides: [
          cloudStreamRepositoryProvider.overrideWith(() => repository),
          cloudStreamEngineHostProvider.overrideWithValue(host),
          deviceProfileProvider.overrideWith((ref) async => const DeviceProfile()),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CloudStreamScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    return (repository, host);
  }

  testWidgets('Settings shows only for an extension with a screen', (tester) async {
    await boot(tester, hasSettings: null);
    expect(find.byTooltip('Settings'), findsNothing);
    await boot(tester, hasSettings: false);
    expect(find.byTooltip('Settings'), findsNothing);
    await boot(tester);
    expect(find.byTooltip('Settings'), findsOneWidget);
  });

  testWidgets('Support shows only while the extension has pop-ups kept', (tester) async {
    await boot(tester);
    expect(find.byTooltip('Support'), findsNothing);
    await boot(
      tester,
      popups: {
        '/x/Alpha.cs3': ['Support us'],
      },
    );
    expect(find.byTooltip('Support'), findsOneWidget);
  });

  testWidgets('Support opens the kept pop-ups in the sheet, and nothing reloads after', (tester) async {
    final (repository, host) = await boot(
      tester,
      popups: {
        '/x/Alpha.cs3': ['Support us'],
      },
    );
    await tester.tap(find.byTooltip('Support'));
    await tester.pumpAndSettle();
    expect(find.text('Support us'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Support us'), findsNothing);
    expect(repository.applied, isEmpty, reason: "a pop-up's screen doesn't apply settings");
    expect(host.sent, ['1 close']);
  });

  testWidgets('an extension being applied says so', (tester) async {
    await boot(tester, applying: {CloudStreamRepository.keyOf(_info)});
    expect(find.text('Applying settings…'), findsOneWidget);
  });

  testWidgets('a change in the sheet applies once it closes', (tester) async {
    final (repository, host) = await boot(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Second provider'), findsOneWidget);
    await tester.tap(find.text('Second provider'));
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(host.sent, ['1 click', '1 close']);
    expect(find.text('Second provider'), findsNothing);
    expect(repository.applied, ['Alpha']);
    expect(find.text("Alpha's settings applied"), findsOneWidget);
  });

  testWidgets('a sheet closed without a change applies nothing', (tester) async {
    final (repository, _) = await boot(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(repository.applied, isEmpty);
  });

  testWidgets('a screen whose extension crashed closes, says so, and still applies what changed', (tester) async {
    final (repository, host) = await boot(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second provider'));
    await tester.pump();
    host.crash(3);
    await tester.pumpAndSettle();
    expect(find.text('Second provider'), findsNothing);
    expect(find.textContaining("Alpha's settings stopped"), findsOneWidget);
    expect(repository.applied, ['Alpha']);
  });

  testWidgets('a sheet taken away while its screen is open closes the screen before the change applies', (
    tester,
  ) async {
    final (repository, host) = await boot(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second provider'));
    await tester.pump();
    // The app navigates away under the sheet: its route goes without Back reaching it.
    Navigator.of(tester.element(find.text('Second provider'))).pop();
    await tester.pumpAndSettle();
    expect(host.closed, ['3 true']);
    expect(repository.applied, ['Alpha']);
  });

  testWidgets("a screen that doesn't open says why", (tester) async {
    final (_, host) = await boot(tester);
    host.failing = true;
    await tester.tap(find.byTooltip('Settings'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining("Couldn't open Alpha's settings"), findsOneWidget);
  });

  testWidgets('a double tap on Settings opens one screen; once it closes, Settings opens it again', (tester) async {
    final (_, host) = await boot(tester);
    host.holdOpen = Completer();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.byTooltip('Settings'));
    host.holdOpen!.complete();
    host.holdOpen = null;
    await tester.pumpAndSettle();
    expect(host.opened, 1);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(host.opened, 2);
  });
}
