import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/extensions/engine/js_engine.dart';

/// Audit W24 — a third-party plugin that asks for a media URL instead of a
/// page used to pull the whole file into a Dart String on the main isolate.
/// [fetchCappedPlainBody] must refuse anything past
/// [kJsHttpMaxResponseBytes], and must refuse it *without* transferring the
/// body: the point of the cap is the memory and the transfer, not a tidier
/// error message.
void main() {
  const int chunk = 512 * 1024;

  Dio dioServing(_FakeAdapter adapter) {
    final Dio dio = Dio();
    dio.httpClientAdapter = adapter;
    return dio;
  }

  Options plainGet() => Options(
    method: 'GET',
    validateStatus: (_) => true,
    followRedirects: true,
  );

  test('the cap is generous enough for any real scraper', () {
    expect(kJsHttpMaxResponseBytes, 8 * 1024 * 1024);
  });

  test('aborts mid-stream once the body passes the cap, leaving the rest of '
      'the transfer unread', () async {
    // 16 MB with no Content-Length — a chunked video response.
    final _FakeAdapter adapter = _FakeAdapter(chunkBytes: chunk, chunks: 32);
    final Dio dio = dioServing(adapter);

    await expectLater(
      fetchCappedPlainBody(
        dio,
        'https://plugin.test/movie.mp4',
        options: plainGet(),
      ),
      throwsA(isA<JsHttpResponseTooLargeException>()),
    );

    // 8 MB cap over 512 KB chunks trips on the 17th; allow slack for the
    // cancellation to land, but nothing like the whole 32.
    expect(
      adapter.chunksEmitted,
      lessThan(24),
      reason:
          'the connection must be torn down, not drained: '
          '${adapter.chunksEmitted} of 32 chunks were pulled',
    );
    expect(adapter.chunksEmitted, greaterThan(8));
  });

  test(
    'rejects an over-sized Content-Length before reading any body',
    () async {
      final _FakeAdapter adapter = _FakeAdapter(
        chunkBytes: chunk,
        chunks: 32,
        headers: <String, List<String>>{
          Headers.contentLengthHeader: <String>['${20 * 1024 * 1024}'],
        },
      );
      final Dio dio = dioServing(adapter);

      await expectLater(
        fetchCappedPlainBody(
          dio,
          'https://plugin.test/huge.bin',
          options: plainGet(),
        ),
        throwsA(
          isA<JsHttpResponseTooLargeException>().having(
            (JsHttpResponseTooLargeException e) => e.declaredLength,
            'declaredLength',
            20 * 1024 * 1024,
          ),
        ),
      );

      expect(
        adapter.chunksEmitted,
        0,
        reason:
            'Content-Length already said it was too big — the body must '
            'never be pulled off the socket at all',
      );
    },
  );

  test(
    'a normal page comes back byte-identical to the old plain transform',
    () async {
      const String page = '<html><body>café — ok</body></html>';
      final _FakeAdapter adapter = _FakeAdapter.text(
        page,
        headers: <String, List<String>>{
          'content-type': <String>['text/html; charset=utf-8'],
          Headers.contentLengthHeader: <String>['${page.length}'],
        },
      );
      final Dio dio = dioServing(adapter);

      final CappedHttpResponse response = await fetchCappedPlainBody(
        dio,
        'https://plugin.test/page',
        options: plainGet(),
      );

      expect(response.body, page);
      expect(response.statusCode, 200);
      expect(response.realUri.toString(), 'https://plugin.test/page');
      expect(
        response.headers.value('content-type'),
        'text/html; charset=utf-8',
      );
    },
  );

  test('a body exactly at the cap is still delivered', () async {
    final _FakeAdapter adapter = _FakeAdapter(
      chunkBytes: kJsHttpMaxResponseBytes,
      chunks: 1,
    );
    final Dio dio = dioServing(adapter);

    final CappedHttpResponse response = await fetchCappedPlainBody(
      dio,
      'https://plugin.test/big-but-legal',
      options: plainGet(),
    );

    expect(response.body.length, kJsHttpMaxResponseBytes);
  });
}

/// Serves a counted stream so a test can tell how much of the body the caller
/// actually pulled off the socket.
///
/// Chunks arrive on a timer rather than synchronously on listen: a real
/// socket does not hand over 20 MB the instant you subscribe, and a fake that
/// does would hide whether the caller hung up early.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({
    required this.chunkBytes,
    required this.chunks,
    this.headers = const <String, List<String>>{},
  }) : _text = null;

  _FakeAdapter.text(
    String text, {
    this.headers = const <String, List<String>>{},
  }) : _text = text,
       chunkBytes = 0,
       chunks = 1;

  final int chunkBytes;
  final int chunks;
  final Map<String, List<String>> headers;
  final String? _text;

  int chunksEmitted = 0;

  Uint8List _chunk() {
    final String? text = _text;
    if (text != null) return Uint8List.fromList(utf8.encode(text));
    // 0x61 = 'a', so the decoded body is valid UTF-8 of the same length.
    return Uint8List(chunkBytes)..fillRange(0, chunkBytes, 0x61);
  }

  Stream<Uint8List> _body() {
    late final StreamController<Uint8List> controller;
    bool cancelled = false;

    Future<void> pump() async {
      for (int i = 0; i < chunks; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        if (cancelled) return;
        chunksEmitted++;
        controller.add(_chunk());
      }
      if (!cancelled) await controller.close();
    }

    controller = StreamController<Uint8List>(
      onListen: () => unawaited(pump()),
      onCancel: () => cancelled = true,
    );
    return controller.stream;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody(_body(), 200, headers: headers);

  @override
  void close({bool force = false}) {}
}
