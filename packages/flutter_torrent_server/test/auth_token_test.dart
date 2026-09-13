import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_torrent_server/src/auth_token.dart';

void main() {
  test('generateAuthToken returns 256 bits of lowercase hex', () {
    final token = generateAuthToken();
    expect(token.length, authTokenBytes * 2);
    expect(RegExp(r'^[0-9a-f]+$').hasMatch(token), isTrue, reason: token);
  });

  test('generateAuthToken never repeats', () {
    final seen = <String>{};
    for (var i = 0; i < 200; i++) {
      expect(seen.add(generateAuthToken()), isTrue);
    }
  });

  test('generateAuthToken spreads across the whole byte range', () {
    // A token built from a weak generator (or one that dropped the high bit,
    // or padded wrong) would not cover the space. 200 tokens is 6400 bytes;
    // all 256 values should show up.
    final values = <String>{};
    for (var i = 0; i < 200; i++) {
      final token = generateAuthToken();
      for (var j = 0; j < token.length; j += 2) {
        values.add(token.substring(j, j + 2));
      }
    }
    expect(values.length, 256);
  });
}
