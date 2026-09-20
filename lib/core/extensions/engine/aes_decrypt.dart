/// AES decryption for the `crypto_decrypt_aes` bridge call, which scraper
/// plugins use to unwrap obfuscated stream URLs.
///
/// This used to go through package:encrypt, a thin wrapper over the same
/// pointycastle primitives. encrypt has had no release since September 2023 and
/// was the only thing holding pointycastle at 3.x, which in turn kept the
/// discontinued `js` package in the dependency graph. The wrapper was ten lines
/// of work, so it is done here instead.
///
/// Behaviour is deliberately identical to what encrypt did, including the
/// details a plugin could depend on: CBC with PKCS7 padding, GCM with a
/// 128-bit tag appended to the ciphertext, and malformed UTF-8 replaced rather
/// than thrown on (`allowMalformed: true`).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Base64 that plugins emit is often whitespace-wrapped and unpadded.
String normalizeBase64(String s) {
  var c = s.replaceAll(RegExp(r'\s+'), '');
  while (c.length % 4 != 0) {
    c += '=';
  }
  return c;
}

/// Decrypts base64 [data] with base64 [key] and [iv].
///
/// [mode] is `gcm` or anything else for CBC, matching the bridge's contract.
String aesDecryptBase64({
  required String key,
  required String iv,
  required String data,
  required String mode,
}) {
  final keyBytes = base64.decode(normalizeBase64(key));
  final ivBytes = base64.decode(normalizeBase64(iv));
  final cipherText = base64.decode(normalizeBase64(data));

  final Uint8List plain;
  if (mode.toLowerCase() == 'gcm') {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        // 128-bit tag, no associated data - what encrypt's AESMode.gcm used.
        AEADParameters(
          KeyParameter(keyBytes),
          128,
          ivBytes,
          Uint8List(0),
        ),
      );
    plain = cipher.process(cipherText);
  } else {
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    )..init(
      false,
      PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
        ParametersWithIV(KeyParameter(keyBytes), ivBytes),
        null,
      ),
    );
    plain = cipher.process(cipherText);
  }

  return utf8.decode(plain, allowMalformed: true);
}
