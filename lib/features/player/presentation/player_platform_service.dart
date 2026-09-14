/// Platform plumbing the player screen needs but should not own: Android
/// picture-in-picture, device orientation, and desktop full screen.
///
/// Every entry point is a no-op where the platform has no equivalent, never a
/// throw, so call sites need no capability checks of their own.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../../../core/providers/device_info_provider.dart';

/// Re-exported so a screen can mirror window state without importing the
/// window plugin itself.
export 'package:window_manager/window_manager.dart' show WindowListener;

/// Set while a route is drawing to the window's own edges.
///
/// The desktop title bar is drawn over every route and is an ancestor of them
/// all, so nothing below the router can reach it; a listenable the shell
/// watches is the only channel. It lives here so the shell only has to know
/// "something wants the whole window", not which screen it was.
final ValueNotifier<bool> immersiveRouteActive = ValueNotifier<bool>(false);

/// How many immersive routes are mounted. A plain bool breaks when two
/// overlap: the inner teardown would uncover the shell over the outer one.
int _immersiveRouteCount = 0;

/// Claims and releases the immersive flag, deferred past the current frame.
///
/// Callers claim from `initState` and release from `dispose`, and the shell
/// listening to this sits in `MaterialApp.builder` rather than below the
/// Navigator, so a synchronous notify throws during build and during the
/// tree lock.
void setImmersiveRoute({required bool active}) {
  _immersiveRouteCount += active ? 1 : -1;
  if (_immersiveRouteCount < 0) _immersiveRouteCount = 0;
  final wanted = _immersiveRouteCount > 0;
  if (immersiveRouteActive.value == wanted) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    immersiveRouteActive.value = _immersiveRouteCount > 0;
  });
}

/// Set while the app is in full screen mode — the ten-foot mode a desktop is
/// put into when it is plugged into a television.
///
/// Written only by `FullScreenMode` in the settings feature. It lives here
/// because [playerFormFactorOf] is a plain function with no `ref` to read a
/// provider through.
final ValueNotifier<bool> fullScreenModeActive = ValueNotifier<bool>(false);

/// The orientation policy a device wants from the player.
///
/// Derived from [DeviceProfile] rather than [Platform]: an Android TV and an
/// Android phone are both `Platform.isAndroid`, and pinning a television to
/// portrait is nonsense.
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
  /// no separate `Platform` check is needed.
  bool get pinsOrientation =>
      this == PlayerFormFactor.phone || this == PlayerFormFactor.tablet;

  /// Whether a finger is the only thing that drives this player.
  ///
  /// The gate for anything that defends against accidental contact, the screen
  /// lock above all. A remote has no accidental surface, a mouse has no
  /// pocket, and [unknown] is still "do not touch".
  ///
  /// A second getter rather than a use of [pinsOrientation], which names the
  /// same two members today and means something else entirely.
  bool get isTouch =>
      this == PlayerFormFactor.phone || this == PlayerFormFactor.tablet;
}

/// Maps the app-wide device profile onto the player's orientation policy.
///
/// Takes the nullable value straight off `deviceProfileProvider.asData`. A
/// profile that has not resolved yet is [PlayerFormFactor.unknown] rather than
/// a guess: guessing "phone" on a television would pin a TV to portrait for
/// the life of the process, and full screen mode is no substitute for a
/// verdict either.
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
/// Delivered by `MainActivity`'s broadcast receiver while the app is in PiP
/// and the Flutter UI is not being touched at all.
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
  static const List<DeviceOrientation> _portrait = [
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ];

  /// The seek distance the PiP buttons advertise — `ic_replay_10` and
  /// `ic_forward_10` in `MainActivity.createPipActions`. Exposed so the
  /// handler cannot drift from the icons on screen.
  static const Duration pipSeekStep = Duration(seconds: 10);

  /// How long a shape has to hold before the player believes it.
  ///
  /// A duration and not a count of readings: every native drops a snapshot
  /// identical to the one before it and a paused engine stops emitting at all,
  /// so a player paused on its first frame would never see a second reading
  /// and never settle.
  ///
  /// 750ms is three of `VlcPlayerController`'s 250ms event ticks, so a track
  /// libVLC revises during startup is still absorbed in silence.
  static const Duration shapeSettleDelay = Duration(milliseconds: 750);

  /// The shape the player is waiting on, and the clock it is waiting out.
  ///
  /// Dropped, not carried, the moment the rendered size becomes unknown again,
  /// so the next episode settles on its own readings.
  Orientation? _shapeCandidate;
  Timer? _shapeSettleTimer;

  /// The orientation this service actually asked the OS for, or null if it
  /// never has.
  ///
  /// Nothing is re-sent while the verdict is unchanged, so a resolution change
  /// inside one landscape film is silent, and nothing is restored unless
  /// something was pinned.
  Orientation? _pinnedOrientation;

  /// Returns whether the window actually shrank. False covers pre-Oreo, a
  /// device that refuses, and a user who has turned PiP off for this app,
  /// which Android reports as a plain `false`.
  ///
  /// [videoSize] shapes the window; without it Android keeps whatever shape it
  /// used last, so a 2.39:1 film is letterboxed inside an already small
  /// window. Null and zero sizes are not sent at all.
  ///
  /// The platform gate reads [defaultTargetPlatform] rather than
  /// `Platform.isAndroid` because only the former can be overridden by a test.
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
  /// Absent rather than zero before the first frame is decoded: Android throws
  /// IllegalArgumentException out of `enterPictureInPictureMode` for an aspect
  /// ratio it does not like.
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
  /// Fire-and-forget: it is driven from a playback-state listener, and a
  /// dropped icon refresh is not worth making that listener async. The catch
  /// is load-bearing — without it a missing native handler surfaces as an
  /// unhandled async error far from this call.
  ///
  /// Carries [videoSize] because the next episode can be shaped differently
  /// from the one that opened the window.
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
  /// Callback-based and state-free: this class has no idea what "play" should
  /// do. The screen owns the controller and decides.
  ///
  /// Not gated on Android: a handler on a channel no other platform sends to
  /// is already inert, and a runtime gate would make the routing untestable.
  ///
  /// The handler is keyed by channel name, so it is process-wide and a second
  /// call replaces the first. [detachPipListener] must run on teardown, or the
  /// handler closes over a dead screen while Android tears the PiP window
  /// down.
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
        // notImplemented(): MainActivity invokes these with no result
        // callback, so the exception would have nowhere to go.
      }
      return null;
    });
  }

  void detachPipListener() => _pipChannel.setMethodCallHandler(null);

  /// Points the device the way the video is shaped, once the video's shape has
  /// stopped changing.
  ///
  /// The only thing that decides orientation in the player; there is no manual
  /// rotate control.
  ///
  /// [renderedSize] must be `VlcPlayerValue.displayVideoSize` and never
  /// `VlcPlayerValue.videoSize`. `videoSize` is the elementary stream's
  /// declared width and height and carries no rotation, so a clip shot in
  /// portrait on a handset — landscape frames plus a 90° rotation matrix — is
  /// reported as 1920x1080 and would turn the device the wrong way.
  /// `displayVideoSize` resolves the rotation: Android applies libVLC's
  /// `ORIENT_IS_SWAP` test to `IMedia.VideoTrack.orientation`, and Darwin's
  /// texture path reports a coded buffer that `vmem.c` has already run
  /// `video_format_ApplyRotation` over. A backend that offers neither reports
  /// null, and then this pins nothing rather than guessing.
  ///
  /// A shape has to hold for [shapeSettleDelay] before it is believed, because
  /// libVLC revises the track it reports during startup. An unknown size —
  /// what every `setMedia` produces while the state is `opening` — drops the
  /// candidate but leaves [_pinnedOrientation] alone, so the device does not
  /// swing back between two episodes; and only a changed verdict is sent, so
  /// an HLS variant switch inside one landscape film stays silent.
  ///
  /// This overrides the OS rotation lock, which neither platform exposes a way
  /// to detect. The pin is always a pair, so the handset can still be turned
  /// end for end, and [restoreOrientation] undoes it on the way out.
  void applyVideoOrientation(
    PlayerFormFactor form, {
    required Size? renderedSize,
  }) {
    // Full screen mode can turn a phone into a `tv` between two ticks, and a
    // candidate armed a moment earlier must not go on to rotate a television.
    if (!form.pinsOrientation) return _dropShapeCandidate();
    if (renderedSize == null ||
        renderedSize.width <= 0 ||
        renderedSize.height <= 0) {
      return _dropShapeCandidate();
    }
    // Square counts as landscape: a 1:1 clip fits either way and landscape is
    // where the controls have room. Decoder buffers are padded up to a
    // multiple of sixteen, so a near-square picture can round across the line
    // either way, and either verdict serves it.
    final wanted = renderedSize.width >= renderedSize.height
        ? Orientation.landscape
        : Orientation.portrait;
    // Already waiting on this verdict. Let the clock run rather than restart
    // it, or a film that ticks four times a second would never settle.
    if (wanted == _shapeCandidate) return;
    _dropShapeCandidate();
    if (wanted == _pinnedOrientation) return;
    _shapeCandidate = wanted;
    _shapeSettleTimer = Timer(shapeSettleDelay, () {
      _shapeSettleTimer = null;
      _shapeCandidate = null;
      _pinnedOrientation = wanted;
      unawaited(
        SystemChrome.setPreferredOrientations(
          wanted == Orientation.landscape ? _landscape : _portrait,
        ),
      );
    });
  }

  /// Forgets the shape being waited on and stops the clock waiting on it.
  ///
  /// Never touches [_pinnedOrientation]: what has already been asked of the OS
  /// is a fact about the device, not part of the settle.
  void _dropShapeCandidate() {
    _shapeSettleTimer?.cancel();
    _shapeSettleTimer = null;
    _shapeCandidate = null;
  }

  /// Hands orientation back to the rest of the app on the way out.
  ///
  /// Phones return to [DeviceOrientation.portraitUp]; anything else is
  /// released with an empty list, meaning "whatever the manifest and
  /// Info.plist already allow". Restoring `DeviceOrientation.values` instead
  /// would unlock rotation app-wide and leave every other screen free to land
  /// sideways.
  ///
  /// Gated on [_pinnedOrientation] rather than on the form factor: a player
  /// closed before the first frame decoded pinned nothing on the way in, and
  /// pinning `portraitUp` on the way out would freeze rotation for the rest of
  /// the process, since nothing else in the app ever calls
  /// `setPreferredOrientations`. The form factor can also have changed
  /// underneath us since the pin.
  ///
  /// Also the only thing that stops the settle clock, so it has to run on the
  /// way out of every session: a [shapeSettleDelay] timer outliving the screen
  /// would rotate the device under whatever came next.
  void restoreOrientation(PlayerFormFactor form) {
    _dropShapeCandidate();
    if (_pinnedOrientation == null) return;
    _pinnedOrientation = null;
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
  /// Not a toggle: the OS window controls can change the state behind us, so
  /// mirrored state would be wrong and leave the viewer stranded in a
  /// chrome-less full-screen window after the video closes. Setting false
  /// unconditionally is a no-op when already windowed.
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
  /// For a caller that already knows which state it wants, where
  /// [toggleFullscreen] would depend on a window state the OS window controls
  /// can change behind its back.
  ///
  /// Returns nothing for the same reason [toggleFullscreen] does not: on macOS
  /// the window is still animating when this completes.
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
  /// Nothing useful could be returned: F11 and the macOS green button move the
  /// window without coming through here, and macOS animates the transition, so
  /// even a truthful answer would be premature. Callers mirror the state from
  /// [WindowListener.onWindowEnterFullScreen] instead.
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
  /// For seeding a mirror on the way in: the window may already have been put
  /// there by F11 or the green button long before the player opened. False
  /// where there is no window at all, which is also the right answer.
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
  /// The indirection exists for the platform gate: window_manager's Dart side
  /// happily registers a listener on Android, where nothing will ever call it.
  void addWindowListener(WindowListener listener) {
    if (Platform.isAndroid || Platform.isIOS) return;
    windowManager.addListener(listener);
  }

  void removeWindowListener(WindowListener listener) {
    if (Platform.isAndroid || Platform.isIOS) return;
    windowManager.removeListener(listener);
  }
}
