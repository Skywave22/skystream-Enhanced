// Audit W26(c) — the plugin engine's Cloudflare cookie jar is data at rest.
//
// It holds `cf_clearance` and whatever session cookies the scraped sites hand
// out, so it is simultaneously a record of which sites the user visits and a
// usable session handoff. In the app's Documents directory that file is
// exposed twice over on iOS: `UIFileSharingEnabled` and
// `LSSupportsOpeningDocumentsInPlace` are both declared in Info.plist, so
// Documents is browsable from Files.app and copied verbatim into an
// unencrypted Finder backup that any paired computer can read.
//
// Application Support is neither file-shared nor exposed, and is where the
// app already keeps its Hive boxes.

import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/extensions/engine/js_engine.dart';
import 'package:skystream/core/storage/extension_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';

class _FakeExtensionRepository extends ExtensionRepository {
  _FakeExtensionRepository() : super(StorageService());
}

/// Answers every request with an empty 200 so the engine's cookie interceptor
/// runs for real. [PersistCookieJar] opens its storage lazily, on the first
/// `loadForRequest`, so nothing touches the disk until a request goes out.
class _EmptyAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString('', 200);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory documents;
  late Directory support;
  late List<String> asked;
  late ReceivePort port;

  setUp(() {
    root = Directory.systemTemp.createTempSync('cf_cookie_jar');
    documents = Directory('${root.path}/Documents')..createSync();
    support = Directory('${root.path}/Library/Application Support')
      ..createSync(recursive: true);
    asked = <String>[];
    // Two *different* directories, so "which one did it pick" is answerable
    // from the filesystem and not only from the channel traffic.
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async {
        asked.add(call.method);
        return switch (call.method) {
          'getApplicationDocumentsDirectory' => documents.path,
          'getApplicationSupportDirectory' => support.path,
          _ => root.path,
        };
      },
    );
    port = ReceivePort();
  });

  tearDown(() {
    port.close();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('the clearance cookie jar is opened outside Documents', () async {
    final Dio dio = Dio()..httpClientAdapter = _EmptyAdapter();
    final JsEngineService engine = JsEngineService.withWorkerPort(
      _FakeExtensionRepository(),
      dio,
      port.sendPort,
    );

    await engine.initCookieJar();
    // Drives the interceptor the jar was installed into, which is what makes
    // the jar open its storage and put a directory on disk.
    await dio.get<void>('https://example.test/');

    expect(
      Directory('${documents.path}/.cf_cookies').existsSync(),
      isFalse,
      reason: 'nothing may be written into the file-shared directory',
    );
    expect(
      Directory('${support.path}/.cf_cookies').existsSync(),
      isTrue,
      reason: 'the jar is on disk under Application Support',
    );

    expect(
      asked,
      contains('getApplicationSupportDirectory'),
      reason: 'the jar must be asked for from Application Support',
    );
    expect(
      asked,
      isNot(contains('getApplicationDocumentsDirectory')),
      reason:
          'Documents is file-shared on iOS — asking for it at all is the bug',
    );
  });
}
