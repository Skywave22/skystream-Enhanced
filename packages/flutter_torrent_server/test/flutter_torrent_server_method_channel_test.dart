import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_torrent_server/flutter_torrent_server_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = MethodChannelFlutterTorrentServer();
  final channel = platform.methodChannel;
  final log = <MethodCall>[];

  void handle(Future<Object?>? Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
          log.add(call);
          return handler(call);
        });
  }

  tearDown(() {
    log.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('authToken is null before start', () {
    expect(platform.authToken, isNull);
  });

  test('start() takes the per-launch token from the native side', () async {
    handle((_) async => {'port': 8090, 'token': 'c' * 64});

    final port = await platform.start();

    expect(port, 8090);
    expect(
      platform.authToken,
      'c' * 64,
      reason:
          'without the token nothing in the app can list torrents or read '
          'settings; the server answers 401',
    );
  });

  test('stop() forgets the token', () async {
    handle((call) async => call.method == 'start'
        ? {'port': 8090, 'token': 'd' * 64}
        : null);

    await platform.start();
    expect(platform.authToken, 'd' * 64);

    await platform.stop();
    expect(platform.authToken, isNull);
  });

  test('a native side that returns no token leaves authToken null', () async {
    handle((_) async => {'port': 8090});

    expect(await platform.start(), 8090);
    expect(platform.authToken, isNull);
  });
}
