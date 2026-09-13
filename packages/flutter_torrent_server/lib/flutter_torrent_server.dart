import 'package:flutter_torrent_server/flutter_torrent_server_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'dart:io';
export 'flutter_torrent_server_desktop.dart';

class FlutterTorrentServer {
  /// Header the embedded server accepts the per-launch token on.
  static const String authTokenHeader =
      FlutterTorrentServerPlatform.authTokenHeader;

  /// Query parameter the embedded server accepts the per-launch token on.
  static const String authTokenQueryParam =
      FlutterTorrentServerPlatform.authTokenQueryParam;

  /// Per-launch token for the running server, or null if it is not running.
  ///
  /// Anything that builds its own HTTP request against the server — listing
  /// torrents, reading or writing settings, fetching a playlist — must send
  /// this as [authTokenHeader], otherwise the server answers 401. Stream URLs
  /// handed to a media engine do not need it.
  String? get authToken => FlutterTorrentServerPlatform.instance.authToken;

  Future<int> start() async {
    final port = await FlutterTorrentServerPlatform.instance.start();

    // Desktop implementation handles its own checks (see flutter_torrent_server_desktop.dart).
    // But for Android/iOS, the platform channel might return before the embedded server
    // is fully listening on the socket. We must verify connection here.
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      int attempts = 0;
      while (attempts < 60) {
        await Future.delayed(const Duration(milliseconds: 500));
        attempts++;

        // Try to establish a TCP connection to verify the server is listening.
        // We try both IPv4 and IPv6 as the server binding depends on the OS/Device.

        // Test 1: IPv4
        try {
          final socket = await Socket.connect(
            '127.0.0.1',
            port,
            timeout: const Duration(milliseconds: 1000),
          );
          socket.destroy();
          return port;
        } catch (_) {}

        // Test 2: IPv6
        try {
          final socket = await Socket.connect(
            '::1',
            port,
            timeout: const Duration(milliseconds: 1000),
          );
          socket.destroy();
          return port; // Success!
        } catch (_) {}
      }
      throw Exception(
        "TorrServer failed to start: Could not establish TCP connection.",
      );
    }
    return port;
  }

  Future<void> stop() {
    return FlutterTorrentServerPlatform.instance.stop();
  }

  Future<String?> addTorrent(String link) {
    return FlutterTorrentServerPlatform.instance.addTorrent(link);
  }

  Future<Map<String, dynamic>?> getTorrentStatus(String hash) {
    return FlutterTorrentServerPlatform.instance.getTorrentStatus(hash);
  }
}
