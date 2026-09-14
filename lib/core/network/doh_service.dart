import 'dart:convert';
import 'dart:math' as math;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'doh_service.g.dart';

/// DNS over HTTPS provider options.
enum DohProvider {
  cloudflare, // https://cloudflare-dns.com/dns-query
  google, // https://dns.google/dns-query
  adguard, // https://dns.adguard.com/dns-query
  dnsWatch, // https://resolver2.dns.watch/dns-query
  quad9, // https://dns.quad9.net/dns-query
  dnsSb, // https://doh.dns.sb/dns-query
  canadianShield, // https://private.canadianshield.cira.ca/dns-query
  custom, // User-defined URL
}

/// Riverpod state for DoH settings.
class DohSettings {
  final bool enabled;
  final DohProvider provider;
  final String customUrl;

  const DohSettings({
    this.enabled = false,
    this.provider = DohProvider.cloudflare,
    this.customUrl = '',
  });

  DohSettings copyWith({
    bool? enabled,
    DohProvider? provider,
    String? customUrl,
  }) {
    return DohSettings(
      enabled: enabled ?? this.enabled,
      provider: provider ?? this.provider,
      customUrl: customUrl ?? this.customUrl,
    );
  }
}

@riverpod
class DohSettingsNotifier extends _$DohSettingsNotifier {
  static const _kEnabledKey = 'doh_enabled';
  static const _kProviderKey = 'doh_provider';
  static const _kCustomUrlKey = 'doh_custom_url';

  @override
  Future<DohSettings> build() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool(_kEnabledKey) ?? false;
      final providerName = prefs.getString(_kProviderKey);
      final customUrl = prefs.getString(_kCustomUrlKey) ?? '';
      final provider = DohProvider.values.firstWhere(
        (p) => p.name == providerName,
        orElse: () => DohProvider.cloudflare,
      );
      final settings = DohSettings(
        enabled: enabled,
        provider: provider,
        customUrl: customUrl,
      );
      await DohService.instance.init();
      DohService.instance.applySettings(settings);
      return settings;
    } catch (_) {
      return const DohSettings();
    }
  }

  Future<void> setEnabled(bool value) async {
    final current = state.asData?.value ?? const DohSettings();
    final updated = current.copyWith(enabled: value);
    state = AsyncData(updated);
    DohService.instance.applySettings(updated);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabledKey, value);
  }

  Future<void> setProvider(DohProvider p) async {
    final current = state.asData?.value ?? const DohSettings();
    final updated = current.copyWith(provider: p);
    state = AsyncData(updated);
    DohService.instance.applySettings(updated);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kProviderKey, p.name);
  }

  Future<void> setCustomUrl(String url) async {
    final current = state.asData?.value ?? const DohSettings();
    final updated = current.copyWith(customUrl: url);
    state = AsyncData(updated);
    DohService.instance.applySettings(updated);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCustomUrlKey, url);
  }

  void clearCache() => DohService.instance.clearCache();
}

/// Whether DoH is actually in effect right now.
///
/// The service falls back to the system resolver whenever DoH cannot answer,
/// so [degraded] lets the Settings UI report a setting that is on but not
/// currently taking effect.
enum DohStatus {
  /// The user has DoH switched off.
  off,

  /// DoH is on and the endpoint is answering.
  active,

  /// DoH is on but the endpoint is unreachable, so lookups are going to the
  /// system resolver. The breaker retries on its own.
  degraded,
}

/// A DNS-over-HTTPS resolver that queries the selected provider for A records.
///
/// Settings state is managed by [dohSettingsProvider] (Riverpod).
/// This class is a singleton for DNS resolution only.
///
/// [resolve] is on the hot path of every socket the app opens (see
/// `dio_client_provider.dart`), so a blocked or black-holed endpoint is
/// contained three ways: a failed lookup is remembered for
/// [kNegativeCacheTtl]; concurrent lookups for one host share a single query;
/// and after [kFailureThreshold] consecutive endpoint failures a circuit
/// breaker skips DoH for a cooldown that grows per trip, then lets one probe
/// through. The breaker never latches for the session.
class DohService {
  DohService._() : _dio = _defaultDio(), _clock = DateTime.now;

  /// An isolated instance with an injectable transport, clock and per-lookup
  /// budget. Production always uses [instance].
  @visibleForTesting
  DohService.forTesting({
    required Dio dio,
    DateTime Function()? clock,
    Duration resolveTimeout = kResolveTimeout,
  }) : _dio = dio,
       _clock = clock ?? DateTime.now,
       _resolveTimeout = resolveTimeout;

  static final DohService instance = DohService._();

  static Dio _defaultDio() => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
    ),
  );

  /// Hard ceiling on one DoH lookup. Dio's own connect/receive timeouts do not
  /// bound the total, and the system resolver is waiting right behind us.
  static const Duration kResolveTimeout = Duration(seconds: 5);

  /// How long a failed lookup is remembered before the network is tried again.
  static const Duration kNegativeCacheTtl = Duration(seconds: 60);

  /// Consecutive endpoint failures that trip the breaker.
  static const int kFailureThreshold = 3;

  /// Cooldown after the first trip; doubles per successive trip.
  static const Duration kBreakerCooldown = Duration(seconds: 30);

  /// Ceiling on the cooldown, so a recovery is still noticed within a few
  /// minutes without the user touching anything.
  static const Duration kBreakerMaxCooldown = Duration(minutes: 5);

  static const int _kMaxCacheEntries = 512;

  final Dio _dio;
  final DateTime Function() _clock;
  Duration _resolveTimeout = kResolveTimeout;

  // In-memory cache: domain -> (ip or null for a negative entry, expiry)
  final Map<String, _DohCacheEntry> _cache = {};

  // domain -> the query already on the wire for it.
  final Map<String, Future<String?>> _inFlight = {};

  int _consecutiveFailures = 0;
  DateTime? _breakerOpenUntil;
  int _breakerTrips = 0;
  bool _halfOpenProbeInFlight = false;

  final ValueNotifier<DohStatus> _status = ValueNotifier<DohStatus>(
    DohStatus.off,
  );

  bool _initialized = false;
  bool _enabled = false;
  DohProvider _provider = DohProvider.cloudflare;
  String _customUrl = '';

  bool get enabled => _enabled;
  DohProvider get provider => _provider;
  String get customUrl => _customUrl;

  /// Never notifies on the per-lookup path — only when the breaker opens or
  /// closes, or the setting itself changes.
  ValueListenable<DohStatus> get status => _status;

  /// True while the breaker is holding DoH off.
  bool get isDegraded => _breakerOpenUntil != null;

  /// Initialize from SharedPreferences. Should be called exactly once at boot.
  Future<void> init() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(DohSettingsNotifier._kEnabledKey) ?? false;
      final providerName = prefs.getString(DohSettingsNotifier._kProviderKey);
      _customUrl = prefs.getString(DohSettingsNotifier._kCustomUrlKey) ?? '';
      _provider = DohProvider.values.firstWhere(
        (p) => p.name == providerName,
        orElse: () => DohProvider.cloudflare,
      );
      _initialized = true;
      _publishStatus();
      if (kDebugMode) {
        debugPrint(
          '[DoH] Eagerly initialized settings -> enabled: $_enabled, provider: ${_provider.name}',
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[DoH] Failed to eager init settings: $e');
    }
  }

  /// Called by [DohSettingsNotifier] to sync state. Public so tests can drive
  /// the service without a SharedPreferences round trip.
  void applySettings(DohSettings settings) {
    final changed =
        settings.enabled != _enabled ||
        settings.provider != _provider ||
        settings.customUrl != _customUrl;
    _enabled = settings.enabled;
    _provider = settings.provider;
    _customUrl = settings.customUrl;
    // The old endpoint's failures say nothing about a new one.
    if (changed) _resetHealth();
    _publishStatus();
  }

  String get _endpoint {
    switch (_provider) {
      case DohProvider.cloudflare:
        return 'https://cloudflare-dns.com/dns-query';
      case DohProvider.google:
        return 'https://dns.google/dns-query';
      case DohProvider.adguard:
        return 'https://dns.adguard.com/dns-query';
      case DohProvider.dnsWatch:
        return 'https://resolver2.dns.watch/dns-query';
      case DohProvider.quad9:
        return 'https://dns.quad9.net/dns-query';
      case DohProvider.dnsSb:
        return 'https://doh.dns.sb/dns-query';
      case DohProvider.canadianShield:
        return 'https://private.canadianshield.cira.ca/dns-query';
      case DohProvider.custom:
        return _customUrl;
    }
  }

  /// Resolves a domain to an IP address using DNS over HTTPS.
  /// Returns null if resolution fails (caller should fall back to normal DNS).
  Future<String?> resolve(String domain) {
    if (!_enabled) return Future<String?>.value(null);

    final now = _clock();

    final cached = _cache[domain];
    if (cached != null && cached.expiry.isAfter(now)) {
      // Serves negative entries too: a host that just failed returns null
      // without re-paying the timeout.
      return Future<String?>.value(cached.ip);
    }

    final pending = _inFlight[domain];
    if (pending != null) return pending;

    if (!_breakerAdmits(now)) return Future<String?>.value(null);

    final future = _lookup(domain);
    _inFlight[domain] = future;
    return future;
  }

  /// Whether the breaker will let one more query onto the wire.
  bool _breakerAdmits(DateTime now) {
    final openUntil = _breakerOpenUntil;
    if (openUntil == null) return true;
    if (openUntil.isAfter(now)) return false;
    // Cooldown lapsed: half-open. Exactly one probe goes out and everyone else
    // keeps using the system resolver until it lands, so a still-broken
    // endpoint costs one timeout per cooldown rather than one per request.
    if (_halfOpenProbeInFlight) return false;
    _halfOpenProbeInFlight = true;
    return true;
  }

  Future<String?> _lookup(String domain) async {
    String? ip;
    int ttl = 300;
    // Distinguishes "the endpoint answered, the name does not exist" from
    // "the endpoint is unreachable". Only the latter feeds the breaker.
    bool endpointAnswered = false;

    try {
      final response = await _dio
          .get<dynamic>(
            _endpoint,
            queryParameters: {
              'name': domain,
              'type': 'A', // IPv4
            },
            options: Options(
              headers: {'Accept': 'application/dns-json'},
              responseType: ResponseType.json,
            ),
          )
          .timeout(_resolveTimeout);

      endpointAnswered = true;

      if (response.statusCode == 200) {
        final data = response.data is String
            ? jsonDecode(response.data as String)
            : response.data;

        if (data['Status'] == 0 && data['Answer'] != null) {
          final answers = data['Answer'] as List;
          // Find A record (type 1)
          for (final answer in answers) {
            if (answer['type'] == 1) {
              ip = answer['data'] as String;
              ttl = answer['TTL'] as int? ?? 300;
              break;
            }
          }
        }
      } else {
        // A 4xx/5xx from the resolver is the endpoint misbehaving, not a
        // missing name — treat it as a failure so the breaker can react.
        endpointAnswered = false;
      }
    } catch (e) {
      endpointAnswered = false;
      if (kDebugMode) debugPrint('[DoH] Failed to resolve $domain: $e');
    } finally {
      _dropInFlight(domain);
      _halfOpenProbeInFlight = false;
    }

    final now = _clock();
    if (ip != null) {
      _cache[domain] = _DohCacheEntry(
        ip: ip,
        expiry: now.add(Duration(seconds: ttl)),
      );
      if (kDebugMode) debugPrint('[DoH] $domain -> $ip (TTL: ${ttl}s)');
    } else {
      _cache[domain] = _DohCacheEntry(
        ip: null,
        expiry: now.add(kNegativeCacheTtl),
      );
    }
    _prune(now);

    if (endpointAnswered) {
      _recordEndpointSuccess();
    } else {
      _recordEndpointFailure(now);
    }

    return ip; // null -> caller falls back to normal DNS
  }

  /// `Map.remove` returns the stored `Future`, which trips `unawaited_futures`
  /// at the call site; the future is the one this call is already inside.
  void _dropInFlight(String domain) {
    _inFlight.remove(domain);
  }

  void _recordEndpointSuccess() {
    _consecutiveFailures = 0;
    if (_breakerOpenUntil == null) return;
    _breakerOpenUntil = null;
    _breakerTrips = 0;
    if (kDebugMode) debugPrint('[DoH] endpoint recovered; breaker closed');
    _publishStatus();
  }

  void _recordEndpointFailure(DateTime now) {
    _consecutiveFailures++;
    final wasOpen = _breakerOpenUntil != null;
    if (!wasOpen && _consecutiveFailures < kFailureThreshold) return;

    // Successive trips back off, capped, so a long outage costs almost nothing
    // while a brief one is noticed again quickly.
    _breakerTrips = math.min(_breakerTrips + 1, 8);
    final millis = math.min(
      kBreakerCooldown.inMilliseconds * (1 << (_breakerTrips - 1)),
      kBreakerMaxCooldown.inMilliseconds,
    );
    _breakerOpenUntil = now.add(Duration(milliseconds: millis));
    _consecutiveFailures = 0;
    if (kDebugMode) {
      debugPrint(
        '[DoH] endpoint unreachable; using system resolver for ${millis ~/ 1000}s',
      );
    }
    if (!wasOpen) _publishStatus();
  }

  void _resetHealth() {
    _cache.clear();
    _consecutiveFailures = 0;
    _breakerOpenUntil = null;
    _breakerTrips = 0;
    _halfOpenProbeInFlight = false;
  }

  void _publishStatus() {
    _status.value = !_enabled
        ? DohStatus.off
        : (_breakerOpenUntil != null ? DohStatus.degraded : DohStatus.active);
  }

  void _prune(DateTime now) {
    if (_cache.length <= _kMaxCacheEntries) return;
    _cache.removeWhere((_, entry) => !entry.expiry.isAfter(now));
    if (_cache.length > _kMaxCacheEntries) _cache.clear();
  }

  /// Clears the DNS cache and gives a tripped breaker an immediate retry.
  void clearCache() {
    _resetHealth();
    _publishStatus();
  }
}

class _DohCacheEntry {
  /// Null for a negative entry: the lookup was attempted and did not yield an
  /// address, so do not attempt it again until [expiry].
  final String? ip;
  final DateTime expiry;
  _DohCacheEntry({required this.ip, required this.expiry});
}
