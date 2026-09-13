/// The one thing the update-prompt preference has to do that an in-memory
/// stand-in cannot prove: survive the process.
///
/// "Later" used to last exactly as long as the run it was said in, so the same
/// dialog for the same release came back on the next cold start, and the one
/// after that. The policy around this pair - who writes it, when, and what it
/// suppresses - is pinned in test/core/widgets/update_prompt_host_test.dart;
/// what is checked here is that a value written before a restart is still there
/// after one, against a real Hive box on disk.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:skystream/core/storage/storage_service.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('declined_update');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => dir.path,
    );
  });

  tearDown(() async {
    await Hive.close();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('nothing is declined on a fresh install', () async {
    final storage = StorageService();
    await storage.init();
    expect(storage.getDeclinedUpdateTag(), isNull);
  });

  test('a declined tag outlives the run it was declined in', () async {
    final first = StorageService();
    await first.init();
    await first.setDeclinedUpdateTag('v2.0.0');
    // A restart: the boxes are closed and opened again off the same directory.
    await Hive.close();

    final second = StorageService();
    await second.init();
    expect(
      second.getDeclinedUpdateTag(),
      'v2.0.0',
      reason: 'the user would be asked about v2.0.0 again on every launch',
    );

    // And a later decline replaces it rather than accumulating.
    await second.setDeclinedUpdateTag('v2.1.0');
    expect(second.getDeclinedUpdateTag(), 'v2.1.0');
  });
}
