/// Compile-time configuration for third-party sync / tracking services.
///
/// Every value below is read from a `--dart-define` flag at build time and
/// embedded as a string constant in the compiled binary, so anyone with an APK
/// or IPA can extract it with `strings`. These are not secrets. The OAuth
/// providers involved already assume public client IDs are public and tolerate
/// the "client secret" being shared with the redirect URL for device / PKCE /
/// implicit flows. Rotate the keys if abuse is detected.
class SyncConfig {
  static const String animeSkipClientId = String.fromEnvironment(
    'ANIMESKIP_CLIENT_ID',
  );

  static const String traktClientId = String.fromEnvironment('TRAKT_CLIENT_ID');
  static const String traktClientSecret = String.fromEnvironment(
    'TRAKT_CLIENT_SECRET',
  );

  static const String anilistClientId = String.fromEnvironment(
    'ANILIST_CLIENT_ID',
  );

  static const String malClientId = String.fromEnvironment('MAL_CLIENT_ID');
  static const String malClientSecret = String.fromEnvironment(
    'MAL_CLIENT_SECRET',
  );
  // MAL OAuth redirect URI. WebViewAuthDialog matches incoming redirects
  // against this by host equality, not string prefix, so it has to stay a
  // parseable URI rather than a fragment.
  static const String malRedirectUri = 'http://localhost';

  static const String simklClientId = String.fromEnvironment('SIMKL_CLIENT_ID');
  static const String simklClientSecret = String.fromEnvironment(
    'SIMKL_CLIENT_SECRET',
  );
}
