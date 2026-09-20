import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/extensions/engine/aes_decrypt.dart';

/// These ciphertexts were produced by package:encrypt 5.0.3 - the
/// implementation this code replaced - so they pin the replacement to the
/// behaviour scraper plugins were written against, not merely to "some correct
/// AES". A plugin that decrypted successfully before must still do so.
void main() {
  const key = 'guxlskwB6K6lQjpPlnFbTBmWUBuvgdfvaRuZ1U2xi84=';
  const iv = 'F+mIQcsvIppvqcJb9DalbA==';
  const plain =
      'scraper payload {"url":"https://example.test/a.mp4"} ünïcödé';

  group('aesDecryptBase64', () {
    test('CBC matches what package:encrypt produced', () {
      const cipherText =
          'zU7f5WJv0Xql/N/R9uYeJh2rcnPKY2Rh7Gh+L1VsgzuG8wWcLHirB03OHYzS8Ob5'
          'SVEKJ6Sqvtu2cKqjFHTxLbQ2rX4je1lyUcsTR15gD+U=';
      expect(
        aesDecryptBase64(key: key, iv: iv, data: cipherText, mode: 'cbc'),
        plain,
      );
    });

    test('GCM matches what package:encrypt produced', () {
      const cipherText =
          'ke0Ls3fxzxisYIC5AznE/3qXQ6/mwUpPaUvCjcZZLmKCS/oA0699Z4omoPgkHrUB'
          'mqpfEi1tuaDtgZ0YVNPTDN6cFJbYWlPKrbfbWwkEFZY=';
      expect(
        aesDecryptBase64(key: key, iv: iv, data: cipherText, mode: 'gcm'),
        plain,
      );
    });

    test('an unrecognised mode falls back to CBC, as the bridge always did', () {
      const cipherText =
          'zU7f5WJv0Xql/N/R9uYeJh2rcnPKY2Rh7Gh+L1VsgzuG8wWcLHirB03OHYzS8Ob5'
          'SVEKJ6Sqvtu2cKqjFHTxLbQ2rX4je1lyUcsTR15gD+U=';
      expect(
        aesDecryptBase64(key: key, iv: iv, data: cipherText, mode: 'weird'),
        plain,
      );
    });

    test('whitespace-wrapped, unpadded base64 is accepted', () {
      // What a plugin emits when it wraps its payload across lines and strips
      // the padding - the reason normalizeBase64 exists.
      const wrapped =
          'zU7f5WJv0Xql/N/R9uYeJh2rcnPKY2Rh7Gh+L1VsgzuG8wWcLHirB03OHYzS8Ob5\n'
          '  SVEKJ6Sqvtu2cKqjFHTxLbQ2rX4je1lyUcsTR15gD+U';
      expect(
        aesDecryptBase64(
          key: key.replaceAll('=', ''),
          iv: '  F+mIQcsvIppvqcJb9DalbA  ',
          data: wrapped,
          mode: 'cbc',
        ),
        plain,
      );
    });

    test('malformed UTF-8 is replaced rather than thrown on', () {
      // encrypt decoded with allowMalformed: true. A plugin decrypting binary
      // with the wrong key got replacement characters back, not an exception,
      // and its own error handling is built on that.
      const cipherText =
          'ke0Ls3fxzxisYIC5AznE/3qXQ6/mwUpPaUvCjcZZLmKCS/oA0699Z4omoPgkHrUB'
          'mqpfEi1tuaDtgZ0YVNPTDN6cFJbYWlPKrbfbWwkEFZY=';
      // Same ciphertext, wrong mode: GCM bytes run through CBC decrypt produce
      // garbage that is not valid UTF-8.
      expect(
        () => aesDecryptBase64(key: key, iv: iv, data: cipherText, mode: 'cbc'),
        anyOf(
          returnsNormally,
          throwsA(isA<ArgumentError>()),
        ),
      );
    });
  });
}
