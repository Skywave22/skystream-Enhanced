import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../logger/app_logger.dart';

/// Cross-platform Cloudflare JS challenge bypass.
class CloudflareBypass {
  CloudflareBypass._();
  static final instance = CloudflareBypass._();

  /// Whether this platform ships a `flutter_inappwebview` implementation.
  ///
  /// A function rather than a plain `Platform.isLinux`, because `dart:io`'s
  /// Platform cannot be overridden the way `debugDefaultTargetPlatformOverride`
  /// can, and this decision needs a test.
  @visibleForTesting
  static bool Function() platformHasWebView = _platformHasWebView;

  static bool _platformHasWebView() => kIsWeb || !Platform.isLinux;

  @visibleForTesting
  static void debugResetPlatformProbe() =>
      platformHasWebView = _platformHasWebView;

  /// How long a headless spawn may take before it is abandoned.
  ///
  /// `run()` can never complete: the Windows plugin wraps controller creation
  /// in a helper that only logs on failure, so on a synchronous HRESULT error
  /// the completion handler never fires. Without a ceiling here the `finally`
  /// that returns the spawn slot never runs.
  ///
  /// A deadlock backstop, not a latency budget. A cold WebView2 or Chromium
  /// init on a slow disk, a low-end TV box or a machine under load can
  /// legitimately take tens of seconds, and abandoning a spawn that would have
  /// succeeded costs the user a working source — so it is deliberately well
  /// above a healthy spawn, which lands in a few seconds.
  ///
  /// 30s, between the original 15s (too tight: it abandoned spawns that were
  /// merely slow) and 60s. It only ever costs anything when a spawn actually
  /// wedges, and with `_maxConcurrentSpawns = 1` that stall is paid by every
  /// caller queued behind it — which is why it is not set higher still.
  /// Shorter than [_timeout], the solve deadline: starting is not the slow
  /// part, solving is.
  @visibleForTesting
  static Duration spawnTimeout = _defaultSpawnTimeout;

  static const Duration _defaultSpawnTimeout = Duration(seconds: 30);

  @visibleForTesting
  static void debugResetSpawnTimeout() => spawnTimeout = _defaultSpawnTimeout;

  // ── WebView2 environment (Windows) ────────────────────────────────────────

  /// Whether this platform needs an explicit [WebViewEnvironment].
  ///
  /// Windows alone: it is a WebView2 concept, and elsewhere
  /// `CookieManager.instance()` resolves a shared default that is already
  /// correct. A function so a test can state the platform.
  @visibleForTesting
  static bool Function() needsWebViewEnvironment = _needsWebViewEnvironment;

  static bool _needsWebViewEnvironment() => !kIsWeb && Platform.isWindows;

  /// Builds the environment. Injectable, because `WebViewEnvironment.create`
  /// dispatches to a platform implementation that is not registered in a unit
  /// test, so the real call is unreachable off Windows.
  @visibleForTesting
  static Future<WebViewEnvironment?> Function(String userDataFolder)
  createEnvironment = _createEnvironment;

  /// Browser arguments for the Windows WebView2 environment.
  ///
  /// `--disable-gpu`, because on Windows this app's WebView is *only ever*
  /// headless: the one widget `InAppWebView` it has is gated off on Windows
  /// and Linux (webview_auth_dialog.dart, which falls back to the system
  /// browser), so nothing WebView2 renders here is ever shown to anyone.
  /// Hardware acceleration therefore buys nothing and costs a GPU process
  /// creating D3D11 devices — on an integrated Radeon that shares system
  /// memory with the CPU, alongside Flutter's own ANGLE device and the
  /// inappwebview plugin's unused one, that contention is a suspect in the
  /// AMD crash reports. WebView2's GPU path is independently known to corrupt
  /// output on some driver/GPU combinations, where disabling acceleration is
  /// the documented workaround (WebView2Feedback#2421).
  ///
  /// KNOWN TRADE-OFF: this changes the Cloudflare fingerprint. With the GPU
  /// off, WebGL falls back to SwiftShader and `WEBGL_debug_renderer_info`
  /// reports a software renderer, which is a bot signal. Plenty of real users
  /// present the same way (blocklisted drivers, VMs, RDP), so it is not an
  /// automatic block, but if Windows solve success drops after this ships,
  /// THIS IS THE FIRST THING TO REVERT.
  ///
  /// Windows-only by construction: [needsWebViewEnvironment] is Windows-only,
  /// so no other platform builds an environment at all and none of this
  /// reaches Android, iOS or macOS.
  @visibleForTesting
  static const windowsBrowserArguments = '--disable-gpu';

  static Future<WebViewEnvironment?> _createEnvironment(String folder) =>
      WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(
          userDataFolder: folder,
          additionalBrowserArguments: windowsBrowserArguments,
        ),
      );

  @visibleForTesting
  static void debugResetEnvironment() {
    needsWebViewEnvironment = _needsWebViewEnvironment;
    createEnvironment = _createEnvironment;
    instance._envFuture = null;
  }

  /// The environment every WebView2 object in this app shares, or null.
  @visibleForTesting
  Future<WebViewEnvironment?> get debugEnvironment => _environment();

  /// The viewport a headless solve reports.
  ///
  /// Not 1x1. The host window is created with `dwStyle 0`, so a 1x1 window has
  /// a 0x0 client rect, and Cloudflare's challenge script inspects viewport
  /// geometry. A plausible desktop size costs nothing and looks like a browser.
  static const Size _headlessViewport = Size(1024, 768);

  /// The in-flight or completed creation, cached.
  ///
  /// A `bool` latch plus a value field would have two holes: a second caller
  /// arriving while the first is still awaiting sees the latch set and the
  /// value still null, so it silently proceeds with no environment; and the
  /// latch is set before the await, so one transient failure pins the
  /// environment to null for the life of the process, sending every later
  /// solve and every cookie read back to the unwritable default folder.
  /// Caching the Future closes both: everyone awaits the same attempt.
  Future<WebViewEnvironment?>? _envFuture;

  /// The shared WebView2 environment, created on first use.
  ///
  /// Created lazily and never at startup: `WebViewEnvironment.create` also
  /// builds its own hidden `CoreWebView2Controller`
  /// (webview_environment.cpp:69-75), so an eager call would put an
  /// `msedgewebview2.exe` on every Windows launch — the opposite of what this
  /// is for.
  ///
  /// Without it, WebView2 uses `<exe_dir>\WebView2` for its user data. The
  /// installer puts the app in Program Files (`setup.iss`, `{autopf}`, with no
  /// `PrivilegesRequired`), which a standard user cannot write to — so on an
  /// installed build environment creation fails and every solve with it.
  Future<WebViewEnvironment?> _environment() {
    if (!needsWebViewEnvironment()) return Future<WebViewEnvironment?>.value();
    return _envFuture ??= _createEnvironmentOnce();
  }

  Future<WebViewEnvironment?> _createEnvironmentOnce() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final folder = p.join(dir.path, 'webview2');
      final env = await createEnvironment(folder);
      if (kDebugMode) debugPrint('$_tag WebView2 user data at $folder');
      return env;
    } catch (e) {
      // Loud, not swallowed: falling back to null means falling back to the
      // Program Files folder, which is the failure being fixed. A caller that
      // sees a null environment on Windows should treat solves as unreliable.
      //
      // The failed result stays cached deliberately. The realistic failure is
      // an unwritable folder, which will still be unwritable on the next solve,
      // and retrying would spawn a WebView2 environment attempt per challenge.
      talker.error('$_tag WebViewEnvironment creation failed', e);
      return null;
    }
  }

  /// The environment the rest of the app must use for WebView2 cookie reads.
  ///
  /// `js_engine.dart` reads `cf_clearance` through `CookieManager`. With no
  /// environment, `CookieManager.instance()` resolves a *different* default
  /// user-data folder from the solver's, so the read comes back empty and
  /// `_injectCfCookies` returns at its `if (webCookies.isEmpty)` guard —
  /// cookie injection dies silently while the solve appears to succeed.
  Future<WebViewEnvironment?> cookieEnvironment() => _environment();

  bool _prewarmed = false;

  /// Pre-warm the system WebView so the first real CF solve doesn't pay the
  /// cold-start cost (~200–500 ms on Android: libwebviewchromium.so load +
  /// AdrenoVK GPU context init). Call this once, a few seconds after the app
  /// is displayed — it runs entirely in the background and disposes itself.
  Future<void> prewarm() async {
    if (_prewarmed) return;
    _prewarmed = true;
    try {
      // Same environment as a real solve, or the warm-up would populate a
      // different user-data folder from the one the solver uses. Prewarm is
      // Android/iOS-only today (main.dart), where this is null anyway.
      final dummy = HeadlessInAppWebView(
        webViewEnvironment: await _environment(),
        initialUrlRequest: URLRequest(url: WebUri('about:blank')),
        initialSettings: InAppWebViewSettings(javaScriptEnabled: false),
      );
      await dummy.run();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await dummy.dispose();
      if (kDebugMode) debugPrint('$_tag WebView pre-warm complete');
    } catch (_) {}
  }

  static const _tag = '[CF Bypass]';
  static const _cfErrorCodes = [403, 503];
  static const _cfServers = ['cloudflare-nginx', 'cloudflare'];
  static const _timeout = Duration(seconds: 60);
  static const _navTimeout = Duration(seconds: 20);
  static const _pollInterval = Duration(milliseconds: 200);

  // ---------------------------------------------------------------------------
  // State Management
  // ---------------------------------------------------------------------------

  /// Active background WebView sessions indexed by `(callerId, host)` so a
  /// solve performed by plugin A can't be reused by plugin B — that would
  /// hand B the cookies / session state A established (audit H6 / PR-08d).
  /// Legacy callers without a callerId share the implicit `'_global_'`
  /// namespace; this only matters during the rollout, since every code
  /// path going through the JS bridge now threads a real namespace.
  final Map<String, _HostWebView> _hostWebViews = {};

  /// Per-`(callerId, host)` deduplication: if we're already solving CF for
  /// a `(callerId, host)` pair, new callers for the same pair share the
  /// same Future instead of spawning a second WebView.
  final Map<String, Future<CfResult?>> _activeByHost = {};

  /// Composite key for cache buckets — keeps the map shape unchanged while
  /// making the scope explicit.
  static String _scopeKey(String? callerId, String host) {
    final scope = (callerId == null || callerId.isEmpty)
        ? '_global_'
        : callerId;
    return '$scope::$host';
  }

  /// Limits concurrent WebView spawns to prevent GPU/RAM exhaustion.
  /// Each HeadlessInAppWebView spawn triggers a full Vulkan/GPU context init
  /// on Android — doing two simultaneously causes severe frame drops (40+
  /// skipped frames). Reusing existing cached sessions bypasses this limit.
  static const _maxConcurrentSpawns = 1;
  int _spawningCount = 0;
  final _spawnQueue = <Completer<void>>[];

  /// When the current slot holder took it, or null when the slot is free.
  ///
  /// This is what makes [_queueTimeout] a watchdog on the *holder* rather than
  /// a stopwatch on the waiter. Without it, a waiter's deadline runs from the
  /// moment it was enqueued, so with a queue of depth N it elapses across N
  /// consecutive healthy holders and fires even though nothing is stuck.
  DateTime? _slotHeldSince;

  Future<void> _acquireSpawnSlot() async {
    if (_spawningCount < _maxConcurrentSpawns) {
      _spawningCount++;
      _slotHeldSince = DateTime.now();
      return;
    }
    final waiter = Completer<void>();
    _spawnQueue.add(waiter);
    while (true) {
      final heldFor = _slotHeldSince == null
          ? Duration.zero
          : DateTime.now().difference(_slotHeldSince!);
      final budget = _queueTimeout - heldFor;
      try {
        // Never a non-positive deadline: that would throw immediately and spin.
        await waiter.future.timeout(
          budget > Duration.zero ? budget : const Duration(milliseconds: 1),
        );
        return;
      } on TimeoutException {
        // Only steal the slot if the *holder* is overdue. A deep queue means
        // this waiter has been here far longer than the holder has held the
        // slot, and stealing then would put a second WebView on the GPU for no
        // reason — precisely the concurrency `_maxConcurrentSpawns = 1` exists
        // to prevent. Not overdue: go round again against the new holder.
        final held = _slotHeldSince == null
            ? Duration.zero
            : DateTime.now().difference(_slotHeldSince!);
        if (held < _queueTimeout) continue;

        // The holder is not coming back. Refusing here would turn one stuck
        // spawn into a permanent outage, which is the failure this bounds, so
        // take the slot and keep the accounting balanced for the release.
        //
        // Unless the slot was handed over in the very tick the timeout fired:
        // `_releaseSpawnSlot` took the queue branch, so it did *not* decrement,
        // which means the slot is already ours. Counting it a second time would
        // leave `_spawningCount` permanently above zero and send every later
        // spawn into this queue forever — a worse outage than the one being
        // bounded.
        if (_spawnQueue.remove(waiter)) {
          _spawningCount++;
          _slotHeldSince = DateTime.now();
        }
        return;
      }
    }
  }

  /// How long a queued caller waits before deciding the slot holder is stuck.
  ///
  /// Measured against [_slotHeldSince] — how long the CURRENT holder has held
  /// the slot — not against how long this waiter has been queued. At queue
  /// depth N those differ by a factor of N, and using the waiter's own clock
  /// let a slow-but-healthy chain of holders push later waiters past the
  /// deadline, breaking the `_maxConcurrentSpawns = 1` mutex and putting
  /// several WebViews on the GPU at once — the exact thing this class exists
  /// to prevent.
  ///
  /// Must exceed a *healthy* holder's worst case: the spawn ([spawnTimeout])
  /// plus the solve poll ([_timeout]) plus environment creation,
  /// `silenceConsole` and the `onSolved` cookie write, so the bound is the sum
  /// of the two long ones with headroom for the rest.
  Duration get _queueTimeout =>
      spawnTimeout + _timeout + const Duration(seconds: 30);

  void _releaseSpawnSlot() {
    if (_spawnQueue.isNotEmpty) {
      // Handover: the slot never goes free, so re-arm the watchdog for the
      // waiter now taking it. Leaving the old timestamp would make the new
      // holder look as though it had been stuck for the previous holder's time
      // as well, and the next waiter would steal the slot straight away.
      _slotHeldSince = DateTime.now();
      _spawnQueue.removeAt(0).complete();
    } else {
      _spawningCount--;
      if (_spawningCount <= 0) _slotHeldSince = null;
    }
  }

  // ---------------------------------------------------------------------------
  // Detection
  // ---------------------------------------------------------------------------

  bool isCloudflareChallenge(
    int? statusCode,
    Map<String, dynamic> headers,
    String body,
  ) {
    if (statusCode == null || !_cfErrorCodes.contains(statusCode)) return false;

    final server = _headerValue(headers, 'server');
    if (server == null ||
        !_cfServers.any((s) => server.toLowerCase().contains(s))) {
      return false;
    }

    return body.contains('Just a moment') ||
        body.contains('cf-mitigated') ||
        body.contains('_cf_chl_opt') ||
        body.contains('challenge-platform');
  }

  // ---------------------------------------------------------------------------
  // Solver
  // ---------------------------------------------------------------------------

  /// Solves the CF challenge and returns the actual page HTML.
  ///
  /// Different hosts solve concurrently. Same-host calls share one in-flight
  /// Future. At most [_maxConcurrentSpawns] WebViews are spawned at once to
  /// avoid GPU/RAM exhaustion; cached sessions are reused for free.
  Future<CfResult?> solveAndFetch(
    String url, {
    String? callerId,
    Future<void> Function(String host)? onSolved,
  }) async {
    // Linux ships no flutter_inappwebview implementation, and the
    // HeadlessInAppWebView constructor in _fetchViaWebView sits OUTSIDE its
    // try, so the null-check TypeError escapes this method entirely and is
    // swallowed by the catch-all in js_engine.dart — which replies
    // {code: 0, body: ''} and destroys the provider's real 403. Declining here
    // removes nothing (nothing worked) and keeps the genuine error intact.
    if (!platformHasWebView()) return null;

    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final rawHost = uri.host;
    if (rawHost.isEmpty) return null;
    final host = _normalizeHost(rawHost);
    // Per-caller cache key: plugin A's solved session is no longer
    // visible to plugin B, so B can't reuse A's cookies / fingerprint.
    // Audit H6 / PR-08d.
    final scopeKey = _scopeKey(callerId, host);

    // 1. Deduplicate: share an already-running solve for the same scope.
    final inFlight = _activeByHost[scopeKey];
    if (inFlight != null) {
      if (kDebugMode) debugPrint('$_tag Joining in-flight solve for $scopeKey');
      return inFlight;
    }

    // 2. Try reusing a cached solved session (free — no spawn slot needed).
    final cachedView = _hostWebViews[scopeKey];
    if (cachedView != null) {
      if (kDebugMode) {
        debugPrint('$_tag Reusing cached WebView for $scopeKey → $url');
      }
      try {
        final html = await cachedView.navigate(url);
        if (html != null &&
            !html.contains('_cf_chl_opt') &&
            !html.contains('Just a moment')) {
          // Cloudflare rotates cf_clearance, and this navigation is where the
          // replacement lands in the WebView's cookie store. `onSolved` is the
          // only caller of _injectCfCookies, so skipping it here left Dio
          // holding a stale cookie: every later plain-HTTP request to the host
          // 403s and escalates to another WebView solve — more spawns, which
          // is exactly what the cached session exists to avoid.
          if (onSolved != null) await onSolved(host);
          return CfResult(body: html, statusCode: 200, finalUrl: url);
        }
        if (kDebugMode) {
          debugPrint('$_tag Cached session stale for $scopeKey, disposing');
        }
        await _disposeHostSession(scopeKey);
      } catch (e) {
        if (kDebugMode) debugPrint('$_tag Cached WebView error: $e');
        await _disposeHostSession(scopeKey);
      }
    }

    // 3. Fresh solve — register future before any await so concurrent callers
    //    for this scope share it rather than spawning duplicate WebViews.
    final future = _freshSolve(url, host, scopeKey, onSolved: onSolved);
    _activeByHost[scopeKey] = future;
    try {
      return await future;
    } finally {
      final orphan = _activeByHost.remove(scopeKey);
      if (orphan != null) unawaited(orphan);
    }
  }

  /// Acquires a spawn slot, runs a fresh WebView solve, then releases the slot.
  /// [host] is the real hostname (used for the `onSolved` callback, which is
  /// where cookie injection per-host happens). [cacheKey] is the composite
  /// `"$caller::$host"` used to index the cache so plugin A's session can't
  /// be reused by plugin B (audit H6 / PR-08d).
  Future<CfResult?> _freshSolve(
    String url,
    String host,
    String cacheKey, {
    Future<void> Function(String host)? onSolved,
  }) async {
    await _acquireSpawnSlot();
    try {
      final result = await _fetchViaWebView(url, cacheKey);
      if (result != null && onSolved != null) await onSolved(host);
      return result;
    } finally {
      _releaseSpawnSlot();
    }
  }

  Future<void> _disposeHostSession(String cacheKey) async {
    final view = _hostWebViews.remove(cacheKey);
    if (view != null) {
      await view.dispose();
    }
  }

  /// Which cached host to evict: the oldest idle one, else the oldest.
  ///
  /// Insertion order is age order, so the first idle entry is the oldest idle
  /// one. Idle is preferred only to avoid disturbing a live navigation — it is
  /// not a safety requirement, because [_HostWebView.dispose] defers the
  /// native teardown while a navigation is in flight and unlists the view
  /// immediately either way.
  ///
  /// So when every view is busy this still returns one, rather than null.
  /// Refusing to evict would be the more cautious-looking choice and the wrong
  /// one: the caller is about to spawn regardless, so the cache would grow
  /// past `_maxCachedWebViews` with no ceiling, and on Windows every extra
  /// view is another msedgewebview2.exe against the same shared GPU memory —
  /// the pressure this cap exists to bound. Null means only "nothing cached".
  @visibleForTesting
  static String? pickEvictionVictim(List<MapEntry<String, bool>> viewsInUse) {
    for (final entry in viewsInUse) {
      if (!entry.value) return entry.key;
    }
    return viewsInUse.isEmpty ? null : viewsInUse.first.key;
  }

  static const _maxCachedWebViews = 2;

  Future<CfResult?> _fetchViaWebView(String url, String cacheKey) async {
    if (kDebugMode) debugPrint('$_tag Starting fresh solve for $url');

    // Evict oldest cached WebViews to prevent GPU memory exhaustion.
    //
    // Never evict one that is mid-navigation. The cached-reuse path in
    // solveAndFetch does NOT register in `_activeByHost` (that guards fresh
    // solves only), so a caller can be parked inside `navigate()` for up to
    // `_navTimeout` with nothing marking the view busy. Evicting it there runs
    // `_headless.dispose()` against a live platform-channel call: on Windows
    // that destroys the ICoreWebView2 out from under an in-flight loadUrl or
    // evaluateJavascript, which faults in-process rather than raising anything
    // Dart can catch. It gets likelier the more distinct hosts are browsed,
    // because each new host forces an eviction — i.e. exactly while
    // navigating.
    while (_hostWebViews.length >= _maxCachedWebViews) {
      final victim = pickEvictionVictim([
        for (final e in _hostWebViews.entries) MapEntry(e.key, e.value.inUse),
      ]);
      if (victim == null) break; // nothing cached

      if (kDebugMode) debugPrint('$_tag Evicting cached WebView for $victim');
      await _disposeHostSession(victim);
    }

    final holder = _ViewHolder();
    CfResult? result;
    bool solved = false;
    InAppWebViewController? capturedController;

    Future<void> checkSolved(
      InAppWebViewController controller,
      String? currentUrl,
    ) async {
      if (solved) return;
      try {
        // Cheap check: one tiny JS call, no DOM serialization.
        // Returns '1' when the CF challenge is gone, '0' while it's active.
        final isClear = await controller.evaluateJavascript(
          source: '''
          (function(){
            var t = document.title || '';
            var hasChallenge =
                t === 'Just a moment...' ||
                t.toLowerCase().indexOf('cloudflare') !== -1 ||
                !!document.getElementById('challenge-form') ||
                !!document.querySelector('[data-translate="checking_browser"]') ||
                !!document.querySelector('.cf-mitigated-content') ||
                typeof window._cf_chl_opt !== 'undefined';
            return hasChallenge ? '0' : '1';
          })()
        ''',
        );

        if (isClear != '1') return;

        // Challenge cleared — fetch full HTML exactly once.
        final html = await controller.evaluateJavascript(
          source: 'document.documentElement.outerHTML',
        );
        final body = html?.toString();
        if (body == null || body.isEmpty) return;

        result = CfResult(
          body: body,
          statusCode: 200,
          finalUrl: currentUrl ?? url,
        );
        solved = true;
        holder.hostView?.onLoaded(body);
      } catch (_) {}
    }

    // The constructor itself can throw — it asserts that a platform
    // implementation exists, and Linux ships none. It used to sit above
    // this try, so that throw escaped _fetchViaWebView, _freshSolve and
    // solveAndFetch entirely and was swallowed by the catch-all in
    // js_engine.dart, destroying the provider's real status code on the way.
    // Inside the try it becomes an ordinary null return.
    HeadlessInAppWebView? headless;
    try {
      // Windows only; null everywhere else, which is the correct default.
      final env = await _environment();
      headless = HeadlessInAppWebView(
        webViewEnvironment: env,
        // Explicit, so the solve does not report a 0x0 viewport — see
        // [_headlessViewport].
        initialSize: _headlessViewport,
        initialUrlRequest: URLRequest(url: WebUri(url)),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          domStorageEnabled: true,
          mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        ),
        onWebViewCreated: (c) => capturedController = c,
        onLoadStop: (c, u) => checkSolved(c, u?.toString()),
        onTitleChanged: (c, t) {
          if (!solved) checkSolved(c, null);
        },
        onProgressChanged: (c, p) {
          if (p == 100) checkSolved(c, null);
        },
        onReceivedError: (c, r, e) {
          final isCancel =
              e.type == WebResourceErrorType.CANCELLED ||
              e.description.contains('-999') ||
              e.description.toLowerCase().contains('cancel');
          if (isCancel) {
            return;
          }
          holder.hostView?.onLoaded(null);
        },
        // Suppress console messages from cached pages (e.g. cinemacity's
        // content-protector.min.js polls the DOM in a tight setInterval,
        // flooding the platform channel with ~40 calls/sec of serialized
        // "[object Object]" strings).
        onConsoleMessage: (_, _) {},
      );

      // Bounded: see [spawnTimeout]. An unbounded await here is what holds the
      // single spawn slot forever and disables Cloudflare for the rest of the
      // process on a machine whose WebView runtime is unhealthy.
      //
      // The future is kept rather than discarded, because abandoning it leaks
      // the native view. `dispose()` opens with `if (!_running) return;` and
      // `_running` is only set once `run()` resolves — so a `_disposeQuietly`
      // on the timeout path is a silent no-op, and a spawn that was merely
      // slow (not stuck) goes on to register a real view that nothing ever
      // tears down: an orphaned HWND and WebView2 process per solve. Hanging a
      // dispose off the future cleans up whenever the native side does finish,
      // and costs nothing if it never does.
      final spawn = headless.run();
      try {
        await spawn.timeout(spawnTimeout);
      } on TimeoutException {
        unawaited(
          spawn.then<void>(
            (_) => _disposeQuietly(headless),
            onError: (Object _) {},
          ),
        );
        rethrow;
      }
      final deadline = DateTime.now().add(_timeout);
      while (!solved && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(_pollInterval);
      }

      if (!solved) {
        await _disposeQuietly(headless);
        return null;
      }

      final hostView = _HostWebView(cacheKey, headless, capturedController);
      holder.hostView = hostView;
      _hostWebViews[cacheKey] = hostView;
      hostView.startIdleTimer();

      // Silence the cached page's console to prevent scripts like
      // cinemacity's content-protector.min.js from flooding native logcat
      // and the plugin's method-channel debug layer with ~40 calls/sec.
      await hostView.silenceConsole();

      if (kDebugMode) debugPrint('$_tag WebView session ready for $cacheKey');
      return result;
    } catch (e) {
      // A throwing dispose here would escape _fetchViaWebView and skip the
      // caller's slot release, which is the same wedge the timeout above bounds.
      await _disposeQuietly(headless);
      return null;
    }
  }

  /// Disposes a headless view without ever throwing.
  ///
  /// Nullable because the constructor now sits inside the try: if it was the
  /// thing that threw, there is nothing to dispose.
  Future<void> _disposeQuietly(HeadlessInAppWebView? headless) async {
    if (headless == null) return;
    try {
      await headless.dispose();
    } catch (e) {
      if (kDebugMode) debugPrint('$_tag dispose failed: $e');
    }
  }

  static String _normalizeHost(String host) {
    final h = host.toLowerCase();
    return h.startsWith('www.') ? h.substring(4) : h;
  }

  String? _headerValue(Map<String, dynamic> headers, String key) {
    final value = headers[key] ?? headers[key.toLowerCase()];
    if (value == null) return null;
    if (value is List) return value.isNotEmpty ? value.first.toString() : null;
    return value.toString();
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

class _HostWebView {
  final String host;
  final HeadlessInAppWebView _headless;
  final InAppWebViewController? _controller;

  Completer<String?>? _pending;
  bool _disposed = false;
  Timer? _idleTimer;

  static const _idleTimeout = Duration(seconds: 90);

  _HostWebView(this.host, this._headless, this._controller);

  void startIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleTimeout, () {
      if (_disposed) return;
      // Idle means idle. A view with a navigation in flight is not idle, and
      // disposing it here would destroy the native controller under a live
      // platform-channel call — the same fault the eviction loop avoids via
      // pickEvictionVictim, reached by a different route. Re-arm instead; the
      // navigation's own completion re-arms it again, so nothing is stranded.
      if (inUse) {
        startIdleTimer();
        return;
      }
      try {
        dispose();
      } catch (e) {
        if (kDebugMode) {
          debugPrint('${CloudflareBypass._tag} Idle timer dispose error: $e');
        }
      }
    });
  }

  /// Non-zero while a [navigate] call is in flight, including its retry.
  ///
  /// Read by the eviction loop: disposing a view mid-navigation destroys the
  /// native WebView2 controller under a live platform-channel call. A counter
  /// rather than a flag because [navigate] recurses to retry.
  int _busy = 0;

  bool get inUse => _busy > 0;

  Future<String?> navigate(String url, {int retries = 1}) async {
    // `_disposeRequested` too: a caller that captured this view before it was
    // unlisted can still reach here, and starting new work on a view already
    // queued for teardown only delays the teardown.
    if (_disposed || _disposeRequested || _controller == null) return null;
    startIdleTimer();
    _busy++;
    try {
      return await _navigate(url, retries: retries);
    } finally {
      _busy--;
      // A dispose that arrived while this navigation was in flight was parked
      // rather than run. Now that the last caller is out, honour it.
      if (_busy == 0 && _disposeRequested && !_disposed) {
        unawaited(dispose());
      }
    }
  }

  Future<String?> _navigate(String url, {int retries = 1}) async {
    // Re-read rather than rely on the caller's check: this recurses to retry,
    // and dispose() may have landed across the await in between.
    final controller = _controller;
    if (_disposed || controller == null) return null;

    if (_pending != null && !_pending!.isCompleted) {
      await _pending!.future.catchError((_) => null);
    }

    _pending = Completer<String?>();
    try {
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
      final html = await _pending!.future.timeout(CloudflareBypass._navTimeout);

      if (html == null && retries > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        return await _navigate(url, retries: retries - 1);
      }
      // Re-silence console after each navigation (page reload replaces overrides).
      await silenceConsole();
      return html;
    } on TimeoutException {
      if (!(_pending?.isCompleted ?? true)) _pending!.complete(null);
      return null;
    } catch (e) {
      return null;
    }
  }

  void onLoaded(String? html) {
    if (_pending != null && !_pending!.isCompleted) _pending!.complete(html);
  }

  /// Set when a dispose arrived mid-navigation and was deferred.
  bool _disposeRequested = false;

  Future<void> dispose() async {
    if (_disposed) return;

    // Deferred, not refused. Every caller of this — eviction, the idle timer,
    // and the stale/error paths in solveAndFetch — can land while a
    // navigation is in flight, because the cached-reuse path never registers
    // in `_activeByHost` (that guards fresh solves only). Running
    // `_headless.dispose()` there destroys the native controller under a live
    // platform-channel call; on Windows that faults in-process, with no Dart
    // exception for `navigate()`'s catch to swallow.
    //
    // Guarding here rather than at each call site, because missing one is the
    // whole bug. The view is unlisted immediately so no new caller can adopt
    // it, and `navigate()`'s finally runs the real teardown when the last
    // caller leaves.
    if (_busy > 0) {
      _disposeRequested = true;
      _idleTimer?.cancel();
      if (CloudflareBypass.instance._hostWebViews[host] == this) {
        CloudflareBypass.instance._hostWebViews.remove(host);
      }
      return;
    }

    _disposed = true;
    _idleTimer?.cancel();
    if (_pending != null && !_pending!.isCompleted) {
      if (kDebugMode) {
        debugPrint(
          '${CloudflareBypass._tag} $host: Cancelling active navigation and disposing',
        );
      }
      _pending!.complete(null);
    }
    try {
      if (CloudflareBypass.instance._hostWebViews[host] == this) {
        CloudflareBypass.instance._hostWebViews.remove(host);
      }
      await _headless.dispose();
    } catch (_) {}
  }

  /// Permanently seal all console methods so page scripts (e.g. cinemacity's
  /// content-protector.min.js running in a setInterval) cannot re-enable them
  /// and flood the platform channel with serialized messages.
  ///
  /// Simple assignment (`console.log = noop`) is undone by any script that
  /// re-assigns afterward. `Object.defineProperty` with configurable:false
  /// makes the property non-writable and non-configurable — subsequent writes
  /// silently no-op even inside setInterval callbacks.
  Future<void> silenceConsole() async {
    if (_disposed || _controller == null) return;
    try {
      await _controller.evaluateJavascript(
        source: '''
        (function() {
          var noop = function(){};
          var methods = ['log','info','debug','warn','error','dir','table',
                         'trace','group','groupCollapsed','groupEnd','clear',
                         'count','assert','time','timeLog','timeEnd','timeStamp'];
          methods.forEach(function(m) {
            try {
              Object.defineProperty(console, m, {
                get: function(){ return noop; },
                set: function(){},
                configurable: false
              });
            } catch(_) {}
          });
        })();
      ''',
      );
    } catch (_) {}
  }
}

class _ViewHolder {
  _HostWebView? hostView;
}

class CfResult {
  final String body;
  final int statusCode;
  final String finalUrl;
  const CfResult({
    required this.body,
    required this.statusCode,
    required this.finalUrl,
  });
}
