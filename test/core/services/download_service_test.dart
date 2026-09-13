import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/logger/app_logger.dart';
import 'package:skystream/core/services/download_service.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:talker_flutter/talker_flutter.dart';

/// Two manners problems in the download path, driven through the real
/// [DownloadService] against a mocked `com.bbflight.background_downloader`
/// method channel.
///
/// 1. The notification permission used to be requested during the launch
///    sequence - `DownloadService.init` ran from the first post-frame callback
///    of every cold start and asked for it as step 3, and iOS asked a second
///    time from `AppDelegate.didFinishLaunchingWithOptions`. The very first
///    thing a new user saw, before any app content, was a system modal asking
///    to send notifications the app had nothing to send yet. It has to be
///    asked for where it means something: the moment a download starts.
///
/// 2. `startDownload` reported nothing when it threw. `dir.create` throws a
///    FileSystemException whenever the target is unwritable - the default
///    outcome on Android 11+ once All-files-access is declined - and no caller
///    caught it and nothing was logged, so "Download Now" simply did nothing.
///
/// The channel mock is what makes this observable at all: under `flutter_test`
/// `defaultTargetPlatform` is android, so `FileDownloader().permissions` is
/// the real `AndroidPermissionsService` and every permission question it asks
/// arrives here as a `permissionStatus` / `requestPermission` call.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Must be the first FileDownloader() call in the process - the singleton
  // keeps whichever storage it was built with.
  FileDownloader(persistentStorage: _InMemoryDownloadStorage());

  late Directory tempDir;
  late StorageService storage;
  late ProviderContainer container;
  late DownloadService service;
  late List<String> nativeCalls;
  late PermissionStatus reportedStatus;

  const MethodChannel downloaderChannel = MethodChannel(
    'com.bbflight.background_downloader',
  );
  const MethodChannel pathProviderChannel = MethodChannel(
    'plugins.flutter.io/path_provider',
  );

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('download_service_test');
    nativeCalls = <String>[];
    reportedStatus = PermissionStatus.denied;

    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      pathProviderChannel,
      (MethodCall call) async => tempDir.path,
    );
    messenger.setMockMethodCallHandler(downloaderChannel, (
      MethodCall call,
    ) async {
      nativeCalls.add(call.method);
      switch (call.method) {
        case 'permissionStatus':
          return reportedStatus.index;
        case 'requestPermission':
          // false = "handled synchronously", which keeps the plugin from
          // parking on a completer only the native side can resolve.
          return false;
        case 'enqueue':
          return true;
        case 'popResumeData':
        case 'popStatusUpdates':
        case 'popProgressUpdates':
          return '{}';
        default:
          return null;
      }
    });

    Hive.init(tempDir.path);
    storage = StorageService();
    await storage.init();
    container = ProviderContainer(
      overrides: [storageServiceProvider.overrideWithValue(storage)],
    );
    service = container.read(downloadServiceProvider);
    talker.cleanHistory();
  });

  tearDown(() async {
    container.dispose();
    await Hive.close();
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(downloaderChannel, null);
    messenger.setMockMethodCallHandler(pathProviderChannel, null);
    talker.cleanHistory();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<bool> start({String? directory}) => service.startDownload(
    url: 'https://example.com/a.mp4',
    filename: 'a.mp4',
    directory: directory ?? p.join(tempDir.path, 'out'),
    item: MultimediaItem(
      title: 'A Movie',
      url: 'https://example.com/a',
      posterUrl: '',
    ),
  );

  group('the notification permission is asked in context, not at launch', () {
    test('init() completes without ever asking for it', () async {
      await service.init();

      // This guards the whole of init, not just the deleted lines. The
      // permission question sat at step 3, between `configHoldingQueue`
      // (step 1) and the `pop*` calls that `FileDownloader().start()` makes at
      // step 4, so seeing both ends arrive with nothing in between is what
      // makes the absence meaningful - init really did run past the old site
      // rather than bailing out early.
      expect(nativeCalls, containsAllInOrder(<String>[
        'configHoldingQueue',
        'popProgressUpdates',
      ]));
      expect(
        nativeCalls,
        isNot(contains('permissionStatus')),
        reason:
            'a cold start must not raise the notification prompt; '
            'saw $nativeCalls',
      );
      expect(nativeCalls, isNot(contains('requestPermission')));
    });

    test('the first startDownload asks for it', () async {
      await service.init();
      nativeCalls.clear();

      await expectLater(start(), completion(isTrue));

      expect(nativeCalls, contains('permissionStatus'));
      expect(
        nativeCalls,
        contains('requestPermission'),
        reason: 'status was denied, so the prompt is the point of the call',
      );
    });

    test('a granted permission is not re-requested', () async {
      reportedStatus = PermissionStatus.granted;
      await service.init();
      nativeCalls.clear();

      await start();

      expect(nativeCalls, contains('permissionStatus'));
      expect(nativeCalls, isNot(contains('requestPermission')));
    });

    test('a second download does not prompt again', () async {
      await service.init();
      await start();
      nativeCalls.clear();

      await start(directory: p.join(tempDir.path, 'out2'));

      expect(
        nativeCalls,
        isNot(contains('requestPermission')),
        reason: 'one prompt per process; re-asking on every download is rude',
      );
      expect(nativeCalls, isNot(contains('permissionStatus')));
    });

    test('iOS does not ask a second time from AppDelegate', () {
      // The native half of the same finding, and the only place a Dart test
      // can see it. `requestAuthorization` in
      // `didFinishLaunchingWithOptions` fires before the engine has drawn
      // anything at all, so it beats even the Dart prompt to the screen.
      final File appDelegate = File('ios/Runner/AppDelegate.swift');
      expect(
        appDelegate.existsSync(),
        isTrue,
        reason: 'run this from the package root',
      );
      expect(
        appDelegate.readAsStringSync(),
        isNot(contains('requestAuthorization')),
        reason:
            'the launch sequence must only install the UNUserNotificationCenter '
            'delegate; authorisation is requested by '
            'DownloadService.ensureNotificationPermission',
      );
    });
  });

  group('startDownload reports its own failures', () {
    test('a directory it cannot create is logged and rethrown', () async {
      await service.init();

      // A plain file standing where a parent directory has to go. This is the
      // portable stand-in for the real trigger - Android 11+ with
      // All-files-access declined - and it reaches the same line:
      // `dir.create(recursive: true)` throws FileSystemException.
      final File blocker = File(p.join(tempDir.path, 'not-a-directory'))
        ..writeAsStringSync('x');
      final String unusable = p.join(blocker.path, 'Skystream', 'A Movie');

      await expectLater(
        start(directory: unusable),
        throwsA(isA<FileSystemException>()),
      );

      // The user-visible half is the launcher's job; this is the half that
      // used to leave us with nothing to look at. Before the fix the throw
      // escaped an uncaught async callback and `/logs` stayed empty.
      final String log = _text(talker);
      expect(
        log,
        contains('DownloadService.startDownload failed'),
        reason: 'a silent start failure is unsupportable; log was:\n$log',
      );
      expect(log, contains('a.mp4'));
      expect(log, contains('FileSystemException'));
    });

    test('a successful start logs nothing', () async {
      await service.init();
      talker.cleanHistory();

      await expectLater(start(), completion(isTrue));

      expect(_text(talker), isNot(contains('startDownload failed')));
    });
  });
}

String _text(Talker logger) =>
    logger.history.map((TalkerData e) => e.generateTextMessage()).join('\n');

/// The package's own [PersistentStorage] spawns a background isolate that
/// reaches for `path_provider` through the root isolate token, which a mocked
/// method channel cannot answer - `FileDownloader().ready` then never
/// completes. An in-memory store keeps the real downloader, minus the isolate.
class _InMemoryDownloadStorage implements PersistentStorage {
  final Map<String, TaskRecord> _records = <String, TaskRecord>{};
  final Map<String, Task> _paused = <String, Task>{};
  final Map<String, ResumeData> _resume = <String, ResumeData>{};

  @override
  (String, int) get currentDatabaseVersion => ('memory', 1);

  @override
  Future<(String, int)> get storedDatabaseVersion async =>
      currentDatabaseVersion;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> storeTaskRecord(TaskRecord record) async =>
      _records[record.taskId] = record;

  @override
  Future<TaskRecord?> retrieveTaskRecord(String taskId) async =>
      _records[taskId];

  @override
  Future<List<TaskRecord>> retrieveAllTaskRecords() async =>
      _records.values.toList();

  @override
  Future<void> removeTaskRecord(String? taskId) async =>
      taskId == null ? _records.clear() : _records.remove(taskId);

  @override
  Future<void> storePausedTask(Task task) async => _paused[task.taskId] = task;

  @override
  Future<Task?> retrievePausedTask(String taskId) async => _paused[taskId];

  @override
  Future<List<Task>> retrieveAllPausedTasks() async => _paused.values.toList();

  @override
  Future<void> removePausedTask(String? taskId) async =>
      taskId == null ? _paused.clear() : _paused.remove(taskId);

  @override
  Future<void> storeResumeData(ResumeData resumeData) async =>
      _resume[resumeData.taskId] = resumeData;

  @override
  Future<ResumeData?> retrieveResumeData(String taskId) async =>
      _resume[taskId];

  @override
  Future<List<ResumeData>> retrieveAllResumeData() async =>
      _resume.values.toList();

  @override
  Future<void> removeResumeData(String? taskId) async =>
      taskId == null ? _resume.clear() : _resume.remove(taskId);
}
