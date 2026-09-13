/// Platform plumbing the player screen needs but should not own: Android
/// picture-in-picture, device orientation, and desktop full screen.
///
/// Every entry point is a no-op where the platform has no equivalent, never a
/// throw. One player screen serves phones, tablets, televisions and three
/// desktops, and pushing a capability check to each call site would bury the
/// UI code in `if (Platform.isAndroid)`.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../../../core/providers/device_info_provider.dart';

/// Re-exported so a screen can mirror window state without importing the
/// window plugin itself. Every other window call it makes goes through this
/// file; the mixin should not be the one exception.
export 'package:window_manager/window_manager.dart' show WindowListener;

/// Set while a route is drawing to the window's own edges.
///
/// Desktop stacks its custom title bar over every route, and it is drawn
/// last, so it wins: its hover state lands on the player's back button and
/// title, and its collapsed strip is an invisible band across the top of the
/// video. The bar is an ancestor of every route, so no InheritedWidget the
/// player sets can reach it and nothing below the router can either - a
/// listenable the shell watches is the only direction that works without a
/// NavigatorObserver in the router, which would have to name the player route
/// to be any use.
///
/// Lives here rather than in main.dart so the flag travels with the player's
/// other platform plumbing and the shell only has to know "something wants the
/// whole window", not which screen it was.
final ValueNotifier<bool> immersiveRouteActive = ValueNotifier<bool>(false);

/// How many immersive routes are currently mounted.
///
/// A plain bool breaks the moment two overlap - a deep link on top of a
/// playing episode, or a double-tap that pushes the player twice - because the
/// inner teardown would uncover the shell over the outer one.
int _immersiveRouteCount = 0;

/// Claims and releases the immersive flag, deferred past the current frame.
///
/// Both call sites are illegal moments to notify from: `initState` runs inside
/// the build phase and `dispose` inside the tree-lock, and the shell listening
/// to this sits in `MaterialApp.builder` - a sibling of the Navigator, not a
/// descendant of the widget being built - so a synchronous notify throws
/// "setState() called during build" and "called when the widget tree was
/// locked" respectively.
void setImmersiveRoute({required bool active}) {
  _immersiveRouteCount += active ? 1 : -1;
  if (_immersiveRouteCount < 0) _immersiveRouteCount = 0;
  final wanted = _immersiveRouteCount > 0;
  if (immersiveRouteActive.value == wanted) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    immersiveRouteActive.value = _immersiveRouteCount > 0;
  });
}

/// Set while the app is running in full screen mode — the ten-foot mode a
/// desktop is put into when it is plugged into a television, as against its
/// ordinary windowed mode.
///
/// Owned by `FullScreenMode` in the settings feature, which is the only thing
/// that writes it; it lives here because [playerFormFactorOf] is a plain
/// function with no `ref` to read a provider through, and because the whole
/// value of the flag is what it does to the form factor.
///
/// A [ValueNotifier] rather than a bare bool for the same reason
/// [immersiveRouteActive] is one: the notifier is the single copy of the
/// state, so a mirror can never drift from it.
final ValueNotifier<bool> fullScreenModeActive = ValueNotifier<bool>(false);

/// The orientation policy a device wants from the player.
///
/// Derived from [DeviceProfile] rather than [Platform] because the two
/// disagree in exactly the cases that matter: an Android TV and an Android
/// phone are both `Platform.isAndroid`, and pinning a television to portrait
/// is nonsense.
enum PlayerFormFactor {
  /// Rotates to match the video, and is handed back to portrait on exit.
  phone,

  /// Rotates to match the video, but is released entirely on exit — a tablet
  /// is watchable and browsable either way up.
  tablet,

  /// A fixed landscape panel. Orientation requests are meaningless.
  tv,

  /// A window, not a screen. Orientation requests are meaningless.
  desktop,

  /// The device profile has not resolved yet. Treated as "do not touch": the
  /// player pins nothing, so there is nothing to restore either.
  unknown;

  /// Whether the player is allowed to pin this device to an orientation.
  ///
  /// Doubles as the platform gate for the orientation API: [phone] and
  /// [tablet] are only ever produced from an Android or iOS device profile, so
  /// no separate `Platform` check is needed — or wanted, since it would make
  /// the logic untestable off-device.
  bool get pinsOrientation =>
      this == PlayerFormFactor.phone || this == PlayerFormFactor.tablet;

  /// Whether a finger is the only thing that drives this player.
  ///
  /// The gate for anything that exists to defend against accidental *contact*
  /// — the screen lock above all. A pocket, a lap, a child or a handset
  /// propped on a chest fires the player's gestures on [phone] and [tablet]
  /// and on nothing else: a remote has no accidental surface, a mouse has no
  /// pocket, and [unknown] is still "do not touch".
  ///
  /// Deliberately a second getter rather than a use of [pinsOrientation],
  /// which happens to name the same two members today and means something
  /// entirely different — "may this device be pinned to an orientation".
  /// Overloading it would make an orientation change silently take the lock
  /// away, or the reverse.
  bool get isTouch =>
      this == PlayerFormFactor.phone || this == PlayerFormFactor.tablet;
}

/// Maps the app-wide device profile onto the player's orientation policy.
///
/// Takes the nullable value straight off `deviceProfileProvider.asData` so
/// callers need no null dance; a profile that has not resolved yet is
/// [PlayerFormFactor.unknown] rather than a guess, because guessing "phone" on
/// a television would pin a TV to portrait for the life of the process.
///
/// [fullScreenModeActive] is read here rather than at the call sites on
/// purpose: this is the one place the player decides what shape of device it
/// is on, so it is the one place "the user says this screen is across the
/// room" has to be said. An unresolved profile stays
/// [PlayerFormFactor.unknown] even then — full screen mode changes the
/// verdict, it is not a substitute for having one.
PlayerFormFactor playerFormFactorOf(DeviceProfile? profile) {
  if (kIsWeb || profile == null) return PlayerFormFactor.unknown;
  // isTv wins: a leanback device also measures wide enough to set isTablet.
  // Full screen mode reaches the same verdict by choice, not by hardware.
  if (profile.isTv || fullScreenModeActive.value) return PlayerFormFactor.tv;
  if (profile.isDesktopOS) return PlayerFormFactor.desktop;
  return profile.isTablet ? PlayerFormFactor.tablet : PlayerFormFactor.phone;
}

/// A transport command issued from the picture-in-picture window's buttons.
///
/// These arrive from `MainActivity`'s broadcast receiver while the app is in
/// PiP and the Flutter UI is not being touched at all, so they are the only
/// way those buttons do anything.
enum PipAction { play, pause, seekForward, seekBackward }

class PlayerPlatformService {
  /// Shared with `MainActivity.CHANNEL`. Traffic runs both ways over it:
  /// `enterPip`/`setPipState` out, transport actions and `pipModeChanged` back.
  static const MethodChannel _pipChannel = MethodChannel(
    'dev.akash.skystream.player/pip',
  );

  static const List<DeviceOrientation> _landscape = [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  /// portraitDown is honoured on Android and quietly dropped on iPhone, whose
  /// Info.plist declares only portrait, landscapeLeft and landscapeRight.
  /// Listing it costs nothing and is what an Android user upside-down in bed
  /// expects.
  static const List<DeviceOrientation> _portrait = [
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ];

  /// The seek distance the PiP buttons advertise — `ic_replay_10` and
  /// `ic_forward_10` in `MainActivity.createPipActions`. Exposed so the
  /// handler cannot drift from the icons the user is looking at.
  static const Duration pipSeekStep = Duration(seconds: 10);

  /// Set once the viewer has used the rotate button, so that the next
  /// video-size event does not immediately undo their choice. See
  /// [toggleOrientation].
  bool _rotationChosenByViewer = false;

  /// Returns whether the window actually shrank. False covers pre-Oreo, a
  /// device that refuses, and - the one that matters - a user who has turned
  /// PiP off for this app, which Android reports as a plain `false`.
  ///
  /// [videoSize] shapes the window. Without it Android keeps whatever shape it
  /// used last, so a 2.39:1 film is letterboxed inside a window that is
  /// already small. Null and zero sizes are simply not sent - the native side
  /// keeps the last shape it was given rather than guessing at square.
  ///
  /// The platform gate reads [defaultTargetPlatform] rather than
  /// `Platform.isAndroid`: the two agree on a device, and only one of them can
  /// be overridden by a test, which is what lets the message this sends be
  /// asserted at all.
  Future<bool> enterPip(bool isPlaying, {Size? videoSize}) async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      final entered = await _pipChannel.invokeMethod<bool>('enterPip', {
        'isPlaying': isPlaying,
        ..._videoSizeArgs(videoSize),
      });
      return entered ?? false;
    } catch (e) {
      // Pre-Oreo answers UNSUPPORTED, and a TV or a locked device can refuse
      // outright. Failing to shrink is not worth interrupting playback for.
      if (kDebugMode) debugPrint('PlayerPlatformService.enterPip: $e');
      return false;
    }
  }

  /// The video's shape as MainActivity wants it, or nothing at all.
  ///
  /// Absent rather than zero when the first frame has not been decoded yet:
  /// zero would have to be special-cased on the native side, and a wrong
  /// aspect ratio there is not a cosmetic error - Android throws
  /// IllegalArgumentException out of `enterPictureInPictureMode` for a ratio
  /// it does not like.
  static Map<String, int> _videoSizeArgs(Size? size) {
    if (size == null || size.width <= 0 || size.height <= 0) {
      return const <String, int>{};
    }
    return <String, int>{
      'videoWidth': size.width.round(),
      'videoHeight': size.height.round(),
    };
  }

  /// Keeps the PiP window's middle button showing the right play/pause icon.
  ///
  /// Fire-and-forget on purpose: it is driven from a playback-state listener,
  /// and a dropped icon refresh is not worth making that listener async. The
  /// catch is load-bearing — without it a missing native handler surfaces as
  /// an unhandled async error far from this call.
  ///
  /// Carries [videoSize] for the same reason [enterPip] does: the next episode
  /// can be shaped differently from the one that opened the window, and this
  /// is the message that is already sent when it starts.
  void syncPipState(bool isPlaying, {Size? videoSize}) {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    unawaited(
      _pipChannel
          .invokeMethod<void>('setPipState', {
            'isPlaying': isPlaying,
            ..._videoSizeArgs(videoSize),
          })
          .catchError((Object e) {
            if (kDebugMode) {
              debugPrint('PlayerPlatformService.syncPipState: $e');
            }
          }),
    );
  }

  /// Routes the PiP window's transport buttons and mode changes back to the
  /// screen.
  ///
  /// Deliberately callback-based and state-free: this class has no idea what
  /// "play" should do. The screen owns the controller and decides.
  ///
  /// Not gated on Android. Registering a handler on a channel that no other
  /// platform ever sends to is already inert, and a runtime gate would only
  /// make the routing untestable off-device. What *is* Android-only is the
  /// traffic.
  ///
  /// The handler is keyed by channel name, so it is process-wide and a second
  /// call replaces the first. [detachPipListener] must run on teardown: a
  /// handler left registered closes over a screen that no longer exists, and
  /// Android keeps delivering to it while it tears the PiP window down.
  void attachPipListener({
    required void Function(PipAction action) onAction,
    required void Function(bool inPip) onModeChanged,
  }) {
    _pipChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'pipModeChanged':
          // `== true` rather than a cast: the argument crosses the channel as
          // a dynamic, and a malformed one should not throw into the engine.
          onModeChanged(call.arguments == true);
        case 'play':
          onAction(PipAction.play);
        case 'pause':
          onAction(PipAction.pause);
        case 'seekForward':
          onAction(PipAction.seekForward);
        case 'seekBackward':
          onAction(PipAction.seekBackward);
        // Anything else is ignored rather than answered with
        // notImplemented(). MainActivity invokes these with no result
        // callback, so the exception would have nowhere to go but the Dart
        // error handler.
      }
      return null;
    });
  }

  void detachPipListener() => _pipChannel.setMethodCallHandler(null);

  /// Pins the device to the orientation the video is shaped for.
  ///
  /// Intended for every video-size change, which is where the old player drove
  /// it: a portrait clip should not letterbox itself into a landscape phone.
  /// Sizes are nullable and zero until the first frame is decoded, so the
  /// unknown case is a no-op rather than a guess at landscape.
  ///
  /// Yields to [toggleOrientation] for the rest of the session — an automatic
  /// re-pin that overrides a button the viewer just pressed reads as a bug.
  void applyVideoOrientation(
    PlayerFormFactor form, {
    required int? width,
    required int? height,
  }) {
    if (!form.pinsOrientation || _rotationChosenByViewer) return;
    if (width == null || height == null || width <= 0 || height <= 0) return;
    unawaited(
      SystemChrome.setPreferredOrientations(
        width >= height ? _landscape : _portrait,
      ),
    );
  }

  /// Flips the device between portrait and landscape, for the rotate button.
  ///
  /// Takes the current orientation instead of a BuildContext so the decision
  /// is a pure function of its inputs and does not depend on a widget tree
  /// that may already be unmounting.
  ///
  /// Latches [applyVideoOrientation] off until [restoreOrientation] runs. The
  /// viewer asking for an orientation outranks the aspect ratio of whatever
  /// plays next.
  void toggleOrientation(PlayerFormFactor form, Orientation current) {
    if (!form.pinsOrientation) return;
    _rotationChosenByViewer = true;
    unawaited(
      SystemChrome.setPreferredOrientations(
        current == Orientation.landscape ? _portrait : _landscape,
      ),
    );
  }

  /// Hands orientation back to the rest of the app on the way out.
  ///
  /// Phones return to [DeviceOrientation.portraitUp], the browse UI's only
  /// sensible shape; tablets are released with an empty list, which means
  /// "whatever the manifest and Info.plist already allow". Restoring
  /// `DeviceOrientation.values` instead — as the screen does today — unlocks
  /// rotation app-wide and leaves every other screen free to land sideways.
  ///
  /// Symmetric with the pinning above: form factors that were never pinned are
  /// left alone rather than forced to a default they never had.
  void restoreOrientation(PlayerFormFactor form) {
    _rotationChosenByViewer = false;
    if (!form.pinsOrientation) return;
    unawaited(
      SystemChrome.setPreferredOrientations(
        form == PlayerFormFactor.phone
            ? const [DeviceOrientation.portraitUp]
            : const [],
      ),
    );
  }

  /// Leaves full screen, whatever put the window there.
  ///
  /// Deliberately not a toggle. The player only ever wants to *exit* on the way
  /// out, and a toggle would depend on mirrored state that is wrong the moment
  /// the user uses the OS window control instead of ours - which then leaves
  /// them stranded in a chrome-less full-screen window after the video closes.
  /// Setting false unconditionally is a no-op when already windowed.
  Future<void> exitFullscreen() async {
    if (Platform.isAndroid || Platform.isIOS) return;
    try {
      if (await windowManager.isFullScreen()) {
        await windowManager.setFullScreen(false);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerPlatformService.exitFullscreen: $e');
    }
  }

  /// Puts the window into or out of full screen.
  ///
  /// For a caller that already knows which state it wants — full screen mode,
  /// which owns the flag it is acting on — where [toggleFullscreen] would
  /// depend on a window state the OS window controls can change behind its
  /// back.
  ///
  /// Returns nothing for the same reason [toggleFullscreen] does not: the
  /// window is the only thing that knows, and on macOS it is still animating
  /// when this completes.
  Future<void> setFullscreen(bool fullscreen) async {
    if (Platform.isAndroid || Platform.isIOS) return;
    try {
      await windowManager.setFullScreen(fullscreen);
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerPlatformService.setFullscreen: $e');
    }
  }

  /// Asks the window to change state. It answers by calling back.
  ///
  /// Nothing is returned because nothing useful could be: the window is the
  /// only thing that knows, F11 and the macOS green button move it without
  /// coming through here at all, and macOS animates the transition so even a
  /// truthful answer would be premature. Callers mirror the state from
  /// [WindowListener.onWindowEnterFullScreen] instead - see
  /// [addWindowListener].
  Future<void> toggleFullscreen() async {
    if (Platform.isAndroid || Platform.isIOS) return;
    try {
      await windowManager.setFullScreen(!await windowManager.isFullScreen());
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerPlatformService.toggleFullscreen: $e');
    }
  }

  /// Whether the window is full screen right now.
  ///
  /// For seeding a mirror on the way in - the window may already have been put
  /// there by F11 or the green button long before the player opened. False
  /// where there is no window at all, which is also the right answer: mobile
  /// and television are permanently full screen and have no control to offer.
  Future<bool> isFullscreen() async {
    if (Platform.isAndroid || Platform.isIOS) return false;
    try {
      return await windowManager.isFullScreen();
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerPlatformService.isFullscreen: $e');
      return false;
    }
  }

  /// Subscribes [listener] to the window's own state changes.
  ///
  /// The point of the indirection is the platform gate: window_manager's Dart
  /// side happily registers a listener on Android, where nothing will ever
  /// call it, and the caller should not have to know that.
  void addWindowListener(WindowListener listener) {
    if (Platform.isAndroid || Platform.isIOS) return;
    windowManager.addListener(listener);
  }

  void removeWindowListener(WindowListener listener) {
    if (Platform.isAndroid || Platform.isIOS) return;
    windowManager.removeListener(listener);
  }
}
