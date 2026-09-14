/// Side-car subtitles, from both ends: what [addSideCarSubtitles] asks the
/// engine to do at open, and what the Subtitles tab does when a viewer adds
/// one by hand - observed through the one fake every app-side player test
/// drives, so the argument shapes stay honest and the id growth on
/// `addSubtitle` (100, 101, ...) is the fake's own.
///
/// The tab's half is here because the thing being pinned is libVLC 3's
/// add-slave: it is *queued* to the input thread, so the track does not exist
/// when `addSubtitle` completes and no list read in that turn can carry it.
/// The same fact is why [addSideCarSubtitles] exists at all.
library;

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/side_car_subtitles.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel_row.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_tracks_tab.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart';

import 'fake_vlc_engine.dart';

/// A snapshot that moves nothing but keeps the controller's stall watchdog
/// unarmed: a playing snapshot leaves a 1 s timer pending, and flutter_test
/// checks pending timers before any tear-down runs.
const Map<String, Object?> _paused = <String, Object?>{'state': 'paused'};

/// The labels of every ticked row - the tab's own reading of what the engine
/// says is playing.
List<String> _selectedRows(WidgetTester tester) => tester
    .widgetList<PanelRow>(find.byType(PanelRow, skipOffstage: false))
    .where((row) => row.selected)
    .map((row) => row.label)
    .toList();

/// The label of the row holding primary focus, or null when no row does.
String? _focusedRow() {
  final context = FocusManager.instance.primaryFocus?.context;
  return context?.findAncestorWidgetOfExactType<PanelRow>()?.label;
}

/// A file the picker "returned". Everything the tab reads comes off [uri];
/// the rest of [PlatformFile] is never touched.
final class _PickedFile extends PlatformFile {
  _PickedFile(this.uri);

  @override
  final Uri uri;

  @override
  String get name => uri.pathSegments.last;

  @override
  Never get xFile => throw UnimplementedError();

  @override
  Future<int> length() async => 0;

  @override
  Future<Uint8List> readAsBytes() async => Uint8List(0);

  @override
  Stream<Uint8List> readAsByteStream() => const Stream<Uint8List>.empty();
}

/// The device picker, answering with [pick] (null = the viewer cancelled)
/// instead of a dialog no test host can show.
final class _FakeFilePicker extends FilePickerPlatform {
  _FakeFilePicker(this.pick);

  final Uri? pick;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => pick == null ? null : _PickedFile(pick!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('preferredSubtitleIndex', () {
    test('finds the first entry written in the wanted language', () {
      expect(preferredSubtitleIndex(<String?>['es', 'en', 'en'], 'en'), 1);
    });

    test('matches on the primary subtag, so pt-BR satisfies pt', () {
      expect(preferredSubtitleIndex(<String?>['fr', 'pt-BR'], 'pt'), 1);
      expect(preferredSubtitleIndex(<String?>['PT_br'], 'pt'), 0);
    });

    test('treats und, empty and null as "no language", never a match', () {
      expect(preferredSubtitleIndex(<String?>['und', null, ''], 'en'), isNull);
      expect(preferredSubtitleIndex(<String?>['und'], 'und'), isNull);
      expect(preferredSubtitleIndex(<String?>['en'], null), isNull);
    });

    test('does not pretend to know that eng means en', () {
      expect(preferredSubtitleIndex(<String?>['eng'], 'en'), isNull);
    });
  });

  group('addSideCarSubtitles', () {
    late FakeVlcEngine engine;

    setUp(() {
      engine = FakeVlcEngine()..install();
    });

    tearDown(() => engine.dispose());

    // The first open of a session: setMedia and every addSubtitle are queued
    // and replayed at attach, so this whole function runs against a controller
    // with no view id. Anything here that needs one throws, and the throw does
    // not stay local - it escapes the open chain and fails the playback.
    test('an unattached controller costs the reorder, not the playback', () async {
      final controller = VlcPlayerController();
      addTearDown(controller.dispose);

      // enable: 0 with three files is the case that wants the pre-read, and
      // it is the common one: sources list English first and the preferred
      // language defaults to English.
      await expectLater(
        addSideCarSubtitles(controller, <Uri>[
          Uri.parse('https://example.com/en.srt'),
          Uri.parse('https://example.com/fr.srt'),
          Uri.parse('https://example.com/es.srt'),
        ], enable: 0),
        completes,
      );

      // Nothing reached the engine, because nothing could: the adds are held
      // on the controller until a VlcPlayer attaches it.
      expect(engine.methods, isEmpty);
    });

    test('adds every subtitle, in the order given', () async {
      final controller = await engine.attach();

      await addSideCarSubtitles(controller, <Uri>[
        Uri.parse('https://example.com/en.srt'),
        Uri.parse('https://example.com/es.srt'),
      ]);

      expect(engine.methods, <String>['addSubtitle', 'addSubtitle']);
      expect(
        engine
            .callsTo('addSubtitle')
            .map((c) => (c.arguments as Map<Object?, Object?>)['uri'])
            .toList(),
        <String>['https://example.com/en.srt', 'https://example.com/es.srt'],
      );

      controller.dispose();
    });

    test(
      'selects the wanted side-car instead of whichever was added last',
      () async {
        final controller = await engine.attach();
        // An embedded track already exists, and is what is on.
        engine.subtitle = <Map<String, Object?>>[
          <String, Object?>{'id': 3, 'name': 'Embedded'},
        ];
        engine.activeSubtitleId = 3;

        await addSideCarSubtitles(controller, <Uri>[
          Uri.parse('https://example.com/en.srt'),
          Uri.parse('https://example.com/es.srt'),
          Uri.parse('https://example.com/pt.srt'),
        ], enable: 0);

        // The English file is the first id that was not there beforehand.
        final select = engine.calls.last;
        expect(select.method, 'setSubtitleTrack');
        expect((select.arguments as Map<Object?, Object?>)['id'], 100);

        // And it is what the engine now reports as on - which is the id the
        // panel's Subtitles tab ticks and lands focus on, straight off the
        // controller's value once the snapshot arrives.
        final delivered = await engine.emit(<String, Object?>{
          'state': 'paused',
        });
        expect(delivered['subtitleTrack'], 100);
        expect(controller.value.activeSubtitleTrackId, 100);
        expect(
          controller.value.trackRevision,
          3,
          reason: 'one revision per side-car, so the panel re-reads the list',
        );

        controller.dispose();
      },
    );

    test('asks the engine nothing extra when the last one is wanted', () async {
      final controller = await engine.attach();

      await addSideCarSubtitles(controller, <Uri>[
        Uri.parse('https://example.com/en.srt'),
        Uri.parse('https://example.com/es.srt'),
      ], enable: 1);

      expect(engine.methods, <String>['addSubtitle', 'addSubtitle']);
      expect(
        engine.activeSubtitleId,
        101,
        reason: "add-slave's own select flag already delivered the last one",
      );

      controller.dispose();
    });

    test('leaves the engine alone when there is nothing to add', () async {
      final controller = await engine.attach();

      await addSideCarSubtitles(controller, const <Uri>[], enable: 0);

      expect(engine.methods, isEmpty);

      controller.dispose();
    });
  });

  /// The engine, the controller and a paused first snapshot: what mid-playback
  /// looks like to a panel that is about to open.
  Future<VlcPlayerController> attach(FakeVlcEngine engine) async {
    engine.install();
    // Tear-downs run last-in first-out, so the controller goes first, while
    // the channel it sends `dispose` on still has a handler.
    addTearDown(engine.dispose);
    final controller = await engine.attach();
    addTearDown(controller.dispose);
    await engine.emit(_paused);
    return controller;
  }

  /// Answers the device picker with [pick] for the rest of the test.
  void pickerAnswers(Uri? pick) {
    final previous = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _FakeFilePicker(pick);
    addTearDown(() => FilePickerPlatform.instance = previous);
  }

  /// The real panel, opened on Subtitles as a television opens it: focus goes
  /// into the list, and the panel's own revision listener is running - which
  /// is what re-reads the lists when the engine finally announces a side-car.
  Future<void> pumpPanelOnSubtitles(
    WidgetTester tester,
    VlcPlayerController controller,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final data = ValueNotifier<PanelData>(PanelData.empty);
    addTearDown(data.dispose);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PlayerPanel(
            controller: controller,
            initialTab: PlayerPanelTab.subtitles,
            data: data,
            isTv: true,
            focusOnOpen: true,
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The tab on its own, handed a list the caller controls - the way the panel
  /// hands it whatever the last read returned, however old that is by now.
  Future<void> pumpTracksTab(
    WidgetTester tester, {
    required VlcPlayerController controller,
    required PlayerTrackKind kind,
    required List<VlcTrackDescription> tracks,
    VoidCallback? onTracksChanged,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PlayerTracksTab(
            controller: controller,
            kind: kind,
            tracks: tracks,
            trackInfo: const <VlcMediaTrackInfo>[],
            onTracksChanged: onTracksChanged ?? () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('a side-car the engine has only queued', () {
    /// One embedded track, playing, and an add-slave that behaves the way
    /// libVLC 3's does: queued to the input thread, so the ES does not exist
    /// when `addSubtitle` completes.
    FakeVlcEngine queuedEngine() => FakeVlcEngine()
      ..queueAddedSlaves = true
      ..subtitle = <Map<String, Object?>>[
        <String, Object?>{'id': 3, 'name': 'English'},
      ]
      ..activeSubtitleId = 3;

    testWidgets('is not re-read out of the engine before it exists', (
      tester,
    ) async {
      final engine = queuedEngine();
      final controller = await attach(engine);
      pickerAnswers(Uri.file('/subs/spanish.srt'));
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      await pumpPanelOnSubtitles(tester, controller);
      final readsAtOpen = engine.callsTo('getSubtitleTracks').length;

      await tester.tap(find.text(l10n.loadSubtitleFile));
      await tester.pumpAndSettle();

      expect(
        engine.callsTo('addSubtitle'),
        hasLength(1),
        reason: 'the file did reach the engine',
      );
      expect(
        engine.callsTo('getSubtitleTracks'),
        hasLength(readsAtOpen),
        reason:
            'libVLC 3 queues add-slave to the input thread, so a list read '
            'in this turn is still the pre-add one: it would put the panel '
            'back on a list without the file the viewer just picked, with '
            'nothing ticked, and re-anchor the D-pad on it. The reload waits '
            'for the engine to announce the track.',
      );
      expect(_selectedRows(tester), <String>[
        'English',
      ], reason: 'the tick still follows the engine, which has not moved yet');
    });

    testWidgets('is picked up, ticked and focused when the engine announces '
        'it', (tester) async {
      final engine = queuedEngine();
      final controller = await attach(engine);
      pickerAnswers(Uri.file('/subs/spanish.srt'));
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      await pumpPanelOnSubtitles(tester, controller);

      await tester.tap(find.text(l10n.loadSubtitleFile));
      await tester.pumpAndSettle();
      expect(find.text('spanish.srt'), findsNothing, reason: 'not landed yet');

      // ESAdded on Darwin and Android, the next poll on Windows and Linux:
      // the ES exists, add-slave's select flag has it on, and the snapshot
      // carries a moved trackRevision.
      await engine.landQueuedSlaves(_paused);
      await tester.pumpAndSettle();

      expect(find.text('spanish.srt'), findsOneWidget);
      expect(_selectedRows(tester), <String>['spanish.srt']);
      expect(
        _focusedRow(),
        'spanish.srt',
        reason: 'the reload re-anchors on what is playing now',
      );
    });

    testWidgets('that the engine refuses outright is absorbed, not thrown at '
        'the zone', (tester) async {
      final engine = queuedEngine()..refusedMethods = <String>{'addSubtitle'};
      final controller = await attach(engine);
      pickerAnswers(Uri.file('/subs/spanish.srt'));
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      await pumpPanelOnSubtitles(tester, controller);

      await tester.tap(find.text(l10n.loadSubtitleFile));
      await tester.pumpAndSettle();

      // The row's handler is unawaited: nothing downstream would catch this,
      // and the app installs no PlatformDispatcher.onError.
      expect(tester.takeException(), isNull);
      expect(_selectedRows(tester), <String>['English']);
    });
  });

  group('a track the engine refuses', () {
    testWidgets('does not move the tick, does not reach the zone, and gets '
        'the list read again', (tester) async {
      // The engine carries one subtitle track and has it on. The tab is
      // holding a list with a second row in it - a language the stream
      // dropped when it renegotiated, still on screen because the panel reads
      // the list once and holds it.
      final engine = FakeVlcEngine()
        ..subtitle = <Map<String, Object?>>[
          <String, Object?>{'id': 3, 'name': 'English'},
        ]
        ..activeSubtitleId = 3;
      final controller = await attach(engine);
      var reloads = 0;
      await pumpTracksTab(
        tester,
        controller: controller,
        kind: PlayerTrackKind.subtitle,
        tracks: const <VlcTrackDescription>[
          VlcTrackDescription(id: 3, name: 'English'),
          VlcTrackDescription(id: 7, name: 'German'),
        ],
        onTracksChanged: () => reloads++,
      );

      await tester.tap(find.text('German'));
      await tester.pumpAndSettle();

      expect(
        engine.callsTo('setSubtitleTrack'),
        hasLength(1),
        reason: 'the tap is the bare engine call, as it should be',
      );
      expect(
        tester.takeException(),
        isNull,
        reason:
            'the natives answer track_not_found here (Android when '
            'setAudioTrack comes back false, Darwin from the same guard) and '
            'the handler is unawaited: unabsorbed, it is a console trace and '
            'nothing else',
      );
      expect(_selectedRows(tester), <String>[
        'English',
      ], reason: 'nothing is optimistic: a refused set never moves the tick');
      expect(
        reloads,
        1,
        reason:
            'a refusal says the held list is out of date, so it is read again '
            'and the dead row goes',
      );
    });

    testWidgets('to switch off, or to take a delay, is absorbed too', (
      tester,
    ) async {
      final engine = FakeVlcEngine()
        ..subtitle = <Map<String, Object?>>[
          <String, Object?>{'id': 3, 'name': 'English'},
        ]
        ..activeSubtitleId = 3
        ..refusedMethods = <String>{'disableSubtitle', 'setSubtitleDelay'};
      final controller = await attach(engine);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      await pumpTracksTab(
        tester,
        controller: controller,
        kind: PlayerTrackKind.subtitle,
        tracks: const <VlcTrackDescription>[
          VlcTrackDescription(id: 3, name: 'English'),
        ],
      );

      await tester.tap(find.text(l10n.off));
      await tester.pumpAndSettle();
      expect(engine.callsTo('disableSubtitle'), hasLength(1));
      expect(tester.takeException(), isNull);

      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();
      expect(engine.callsTo('setSubtitleDelay'), hasLength(1));
      expect(tester.takeException(), isNull);

      expect(_selectedRows(tester), <String>[
        'English',
      ], reason: 'the engine said no to both, so nothing on screen moved');
      expect(find.text('+0ms'), findsOneWidget);
    });
  });
}
