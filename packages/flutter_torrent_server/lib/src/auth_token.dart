import 'dart:math';

/// Number of random bytes behind a per-launch token. 32 bytes = 256 bits, the
/// same width the Go side mints when no token is supplied.
const int authTokenBytes = 32;

/// Mints a fresh per-launch token for the embedded torrent server.
///
/// The server binds loopback only, so this is not defending against the
/// network — it is defending against another process on the same device
/// (any Android app holding INTERNET can open a socket to this app's
/// 127.0.0.1) reading the user's torrent list or driving the engine.
///
/// [Random.secure] is required: a seeded [Random] would make the token
/// predictable from the launch time, which is exactly what an attacker on the
/// device can observe.
String generateAuthToken() {
  final rng = Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < authTokenBytes; i++) {
    buf.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}
