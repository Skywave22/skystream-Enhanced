import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skystream/core/storage/storage_service.dart';

/// The recovery contract of `StorageService._safeOpenBox`, exercised through
/// the real method.
///
/// It used to catch ANY failure, "salvage" by re-opening with
/// `crashRecovery: true` — already the default, so the retry was the call that
/// had just thrown — and then delete the box. Every corrupt-box path was
/// therefore an unconditional wipe of the user's library, watch history,
/// settings or plugin data, and a full disk took the same path as real
/// corruption.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late final Directory scratch;
  late StorageService service;

  // Deliberately NOT `dir`. `clearPreferences` empties the temporary directory
  // wholesale, and if path_provider pointed at the Hive directory the boxes
  // would vanish with it and the assertions below would pass without the
  // delete ever running.
  //
  // One directory for the whole file: the cache manager the reset empties is a
  // singleton that keeps the path it was first built with, so a per-test
  // directory leaves the second reset writing into a deleted one.
  setUpAll(() {
    scratch = Directory.systemTemp.createTempSync('hive_recovery_scratch');
  });

  tearDownAll(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  setUp(() {
    dir = Directory.systemTemp.createTempSync('hive_recovery');
    if (!scratch.existsSync()) scratch.createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => scratch.path,
    );
    Hive.init(dir.path);
    service = StorageService();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await Hive.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File boxFile(String name) =>
      File('${dir.path}${Platform.pathSeparator}$name.hive');

  test('an environmental failure is rethrown and the box file survives',
      () async {
    // The case with real-world frequency. Hive's own crashRecovery defaults to
    // true (hive-2.2.3/lib/src/hive_impl.dart:133) and silently repairs the
    // common corruption - an unclean kill during a write - so the old bare
    // `catch` fired mostly on things that were NOT corruption at all: a full
    // disk, a permission error, a second desktop instance holding the lock.
    // Those are transient and the data behind them is intact, and the old code
    // deleted it anyway. Now they must propagate untouched.
    final seed = await Hive.openBox<dynamic>('locked_box');
    await seed.put('precious', 'data');
    await seed.close();
    final f = boxFile('locked_box');
    final bytes = f.lengthSync();

    // Make only the LOCK file unreadable, leaving the DIRECTORY writable.
    // That distinction is the whole test: Hive fails to take its lock and
    // throws, while `deleteBoxFromDisk` - which needs write permission on the
    // directory, not the file - would still succeed. So the old code really
    // could and did delete the data here, and the new code must not.
    final lock = File('${dir.path}${Platform.pathSeparator}locked_box.lock')
      ..createSync();
    Process.runSync('chmod', ['000', lock.path]);
    addTearDown(() => Process.runSync('chmod', ['600', lock.path]));

    // Hive reports the failure by throwing into the zone from inside its own
    // initialize(), not only through the returned future, so both routes are
    // swallowed. The invariant is not how the error is delivered - it is that
    // the user's data is still on disk afterwards.
    var reached = false;
    await runZonedGuarded(() async {
      try {
        final box = await service.debugSafeOpenBox('locked_box', dir: dir.path);
        reached = true;
        await box.close();
      } catch (_) {}
    }, (_, _) {});
    expect(
      reached,
      isFalse,
      reason: 'the open must genuinely fail, or this test proves nothing',
    );

    expect(f.existsSync(), isTrue, reason: 'the box must still be on disk');
    expect(f.lengthSync(), bytes);
    expect(
      dir.listSync().where((e) => e.path.contains('.corrupt-')),
      isEmpty,
      reason: 'nothing was corrupt, so nothing should be quarantined',
    );
  });

  test('an intact box opens untouched and nothing is quarantined', () async {
    final seed = await Hive.openBox<dynamic>('good_box');
    await seed.put('k', 'v');
    await seed.close();

    final box = await service.debugSafeOpenBox('good_box', dir: dir.path);

    expect(box.get('k'), 'v');
    expect(
      dir.listSync().where((e) => e.path.contains('.corrupt-')),
      isEmpty,
      reason: 'a healthy box must never take the recovery path',
    );
    await box.close();
  });

  // The other half of the contract. Refusing to destroy the data is only right
  // if the user is left with a way forward: the rethrow above sends
  // `_AppRootState._init` (lib/main.dart:150-158) into its catch and renders
  // `LaunchErrorApp`, whose only two escapes - "Factory Reset" and "Reset Data
  // (Keep Extensions)" - both run `clearPreferences`. So clearPreferences has
  // to work on a StorageService whose `init()` aborted part-way through
  // assigning its four `late` box fields.
  test('a reset deletes the boxes even when init() never opened them',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    // Seed the four boxes on disk and then close them, so nothing is
    // registered with Hive - the state after an `openBox` that threw, which
    // never reaches `_boxes[name] = newBox` (hive-2.2.3 hive_impl.dart:107).
    const boxes = [
      StorageService.kLibraryBox,
      StorageService.kSettingsBox,
      StorageService.kHistoryBox,
      StorageService.kExtensionsBox,
    ];
    for (final name in boxes) {
      final seed = await Hive.openBox<dynamic>(name);
      await seed.put('k', 'v');
      await seed.close();
      expect(boxFile(name).existsSync(), isTrue);
    }

    // `service` comes straight from setUp: constructed, never init()ed, so
    // every `late Box` field is unassigned. That is precisely what
    // LaunchErrorApp holds, because init() always aborts AT the box that will
    // not open - the box the user needs deleted is always an unassigned one.
    await service.clearPreferences(keepRepos: false);

    for (final name in boxes) {
      expect(
        boxFile(name).existsSync(),
        isFalse,
        reason:
            "'$name' survived the reset. Reading an unassigned `late` field "
            'must not be able to skip the delete, or the next launch fails '
            'identically and the user has no in-app way out.',
      );
    }
  });

  // The settings box holds both subtitle account usernames; the matching
  // passwords are reusable account passwords in the platform secure store.
  // Deleting the box alone leaves the accounts screen reading "Not logged in"
  // on the next launch while the passwords are still on the device - and the
  // startup error screen has no ProviderScope, so the settings notifier cannot
  // be the one to remove them.
  test('a reset takes the subtitle account passwords with the box', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final keychain = <String, String>{
      kOsPasswordKey: 'hunter2',
      kSubDlPasswordKey: 'correct-horse',
      'trakt_access_token': 'oauth-token',
    };
    FlutterSecureStorage.setMockInitialValues(keychain);

    await service.clearPreferences();

    expect(keychain[kOsPasswordKey], isNull);
    expect(keychain[kSubDlPasswordKey], isNull);
    expect(
      keychain['trakt_access_token'],
      'oauth-token',
      reason: 'the reset that keeps extensions keeps OAuth sessions too',
    );
  });
}

