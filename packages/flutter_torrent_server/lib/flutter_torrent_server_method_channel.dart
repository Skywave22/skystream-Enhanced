import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_torrent_server_platform_interface.dart';

/// An implementation of [FlutterTorrentServerPlatform] that uses method channels.
class MethodChannelFlutterTorrentServer extends FlutterTorrentServerPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_torrent_server');

  String? _authToken;

  @override
  String? get authToken => _authToken;

  @override
  Future<int> start() async {
    // The native side mints the per-launch token and hands it back with the
    // port, because it is the side that passes the token into the Go server.
    final result = await methodChannel.invokeMapMethod<String, dynamic>(
      'start',
    );
    _authToken = result?['token'] as String?;
    final port = result?['port'] as int?;
    return port ?? -1;
  }

  @override
  Future<void> stop() async {
    await methodChannel.invokeMethod<void>('stop');
    _authToken = null;
  }

  @override
  Future<String?> addTorrent(String link) async {
    final hash = await methodChannel.invokeMethod<String>('addTorrent', {
      'link': link,
    });
    return hash;
  }

  @override
  Future<Map<String, dynamic>?> getTorrentStatus(String hash) async {
    final status = await methodChannel.invokeMapMethod<String, dynamic>(
      'getTorrentStatus',
      {'hash': hash},
    );
    return status;
  }
}
