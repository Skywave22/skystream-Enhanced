import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/services/external_player_service.dart';

/// What a hand-off to another app can still say about the request.
///
/// A scraped link is frequently bound to the `Referer`, `User-Agent` or
/// `Cookie` it was resolved with. The internal player sends what libVLC can
/// send; a hand-off sends whatever the hand-off has room for, and on three of
/// the five platforms that is nothing. Getting this table wrong is invisible
/// at the call site — the other app opens, the origin answers 403, and the
/// blame lands on the player.
void main() {
  final ExternalPlayerService service = ExternalPlayerService.instance;
  final ExternalPlayer vlc = service.getPlayerById('vlc')!;
  final ExternalPlayer mpv = service.getPlayerById('mpv')!;
  final ExternalPlayer mxPlayer = service.getPlayerById('mx_player')!;
  final ExternalPlayer infuse = service.getPlayerById('infuse')!;
  final ExternalPlayer potPlayer = service.getPlayerById('potplayer')!;

  group('what each hand-off can carry', () {
    test('the Android intent carries none of them', () {
      // MainActivity.kt reads url, package, mimeType and title. There is no
      // extra for a header, so every one of them is dropped.
      for (final ExternalPlayer player in <ExternalPlayer>[vlc, mxPlayer]) {
        expect(
          service.headerSupport(player, platform: TargetPlatform.android),
          ExternalHeaderSupport.none,
        );
      }
      expect(
        service.unsupportedHeaders(mxPlayer, <String, String>{
          'Referer': 'https://origin.test/',
          'User-Agent': 'Mozilla/5.0',
        }, platform: TargetPlatform.android),
        <String>['Referer', 'User-Agent'],
      );
    });

    test('an iOS URL scheme carries none of them', () {
      expect(
        service.headerSupport(infuse, platform: TargetPlatform.iOS),
        ExternalHeaderSupport.none,
      );
      expect(
        service.unsupportedHeaders(infuse, <String, String>{
          'Cookie': 'sid=1',
        }, platform: TargetPlatform.iOS),
        <String>['Cookie'],
      );
    });

    test('macOS `open -a` carries none, the mpv CLI carries all', () {
      // VLC and IINA are launched with `open -a`, which passes the URL as a
      // document; mpv has no .app entry and goes out as a command line.
      expect(
        service.headerSupport(vlc, platform: TargetPlatform.macOS),
        ExternalHeaderSupport.none,
      );
      expect(
        service.headerSupport(mpv, platform: TargetPlatform.macOS),
        ExternalHeaderSupport.any,
      );
      expect(
        service.unsupportedHeaders(mpv, <String, String>{
          'Cookie': 'sid=1',
          'Origin': 'https://origin.test',
        }, platform: TargetPlatform.macOS),
        isEmpty,
      );
    });

    test('the VLC CLI carries User-Agent and Referer and nothing else', () {
      expect(
        service.headerSupport(vlc, platform: TargetPlatform.windows),
        ExternalHeaderSupport.userAgentAndReferer,
      );
      expect(
        service.unsupportedHeaders(vlc, <String, String>{
          'User-Agent': 'Mozilla/5.0',
          'Referrer': 'https://origin.test/',
          'Cookie': 'sid=1',
        }, platform: TargetPlatform.linux),
        <String>['Cookie'],
      );
    });

    test('a player with no documented header option carries none', () {
      expect(
        service.headerSupport(potPlayer, platform: TargetPlatform.windows),
        ExternalHeaderSupport.none,
      );
    });

    test('a stream with no headers is never reported as degraded', () {
      expect(
        service.unsupportedHeaders(
          mxPlayer,
          null,
          platform: TargetPlatform.android,
        ),
        isEmpty,
      );
      expect(
        service.unsupportedHeaders(mxPlayer, const <String, String>{
          'Referer': '',
        }, platform: TargetPlatform.android),
        isEmpty,
      );
    });
  });

  group('the arguments each CLI is given', () {
    test('VLC gets its own two options', () {
      expect(
        service.headerArgs(vlc, <String, String>{
          'User-Agent': 'Mozilla/5.0',
          'Referer': 'https://origin.test/',
          'Cookie': 'sid=1',
        }),
        <String>[
          '--http-user-agent=Mozilla/5.0',
          '--http-referrer=https://origin.test/',
        ],
      );
    });

    test('mpv gets one list entry per field, plus its own two options', () {
      expect(
        service.headerArgs(mpv, <String, String>{
          'User-Agent': 'Mozilla/5.0',
          'Referrer': 'https://origin.test/',
          'Cookie': 'a=1, b=2',
        }),
        <String>[
          '--user-agent=Mozilla/5.0',
          '--referrer=https://origin.test/',
          // One argument per field: the comma-separated form would read the
          // comma inside this cookie as the start of another field.
          '--http-header-fields-append=Cookie: a=1, b=2',
        ],
      );
    });

    test('a value carrying a newline produces no argument at all', () {
      expect(
        service.headerArgs(mpv, <String, String>{
          'Cookie': 'sid=1\r\nX-Injected: 1',
        }),
        isEmpty,
      );
    });

    test('a player that cannot carry headers is given no arguments', () {
      expect(
        service.headerArgs(potPlayer, <String, String>{'Referer': 'https://x'}),
        isEmpty,
      );
    });
  });
}
