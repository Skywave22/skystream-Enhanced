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

  /// How long a shape has to hold before the player believes it.
  ///
  /// Deliberately a duration, and deliberately *not* a count of readings. The
  /// count that shipped was a two-**event** rule dressed up as a two-frame
  /// rule: it waited for two consecutive matching snapshots, but every native
  /// side drops a snapshot identical to the one before it
  /// (`VlcPlayerPlatformView.sendSnapshot`'s `event == lastSentEvent`, the two
  /// Darwin plugins' `lastSentEvent.isEqual`) and a paused engine stops
  /// emitting at all, so a player paused on its first frame never received a
  /// second event and never settled. A shape reported once and then held is
  /// exactly as trustworthy as one reported twice — more so, if anything,
  /// since the engine had the chance to revise it and did not.
  ///
  /// 750ms is three of `VlcPlayerController`'s 250ms event ticks, so a track
  /// libVLC revises during startup is still absorbed in silence, and it is
  /// short enough that the rotation reads as part of the film opening rather
  /// than as a second event.
  static const Duration shapeSettleDelay = Duration(milliseconds: 750);

  /// The shape the player is waiting on, and the clock it is waiting out.
  ///
  /// Dropped — not carried — the moment the rendered size becomes unknown
  /// again, which is how the next episode gets to settle on its own readings.
  Orientation? _shapeCandidate;
  Timer? _shapeSettleTimer;

  /// The orientation this service actually asked the OS for, or null if it
  /// never has.
  ///
  /// The ground truth for two things that used to be guessed at. Nothing is
  /// re-sent while the verdict is unchanged, so a resolution change inside one
  /// landscape film is silent; and nothing is *restored* unless something was
  /// pinned, so a player torn down before the first frame decoded leaves the
  /// device exactly as it found it.
  Orientation? _pinnedOrientation;

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

  /// Points the device the way the video is shaped, once the video's shape has
  /// stopped changing.
  ///
  /// The only thing that decides orientation in the player: there is no manual
  /// rotate control any more, because "which way up should this be" has one
  /// right answer and the video knows it. A landscape film opens landscape and
  /// a portrait clip opens portrait, without the viewer being asked.
  ///
  /// ## [renderedSize] is the *rendered* picture, and that is not negotiable
  ///
  /// It must be `VlcPlayerValue.codedVideoSize` — the dimensions of the buffer
  /// libVLC actually decodes into — and never `VlcPlayerValue.videoSize`.
  /// The two disagree on exactly the video this feature exists for.
  ///
  /// `videoSize` is the elementary stream's *declared* width and height and
  /// carries no rotation:
  ///
  ///  * Darwin's is `VLCMediaPlayer.videoSize` → `libvlc_video_get_size`.
  ///    Disassembling the pinned binaries (VLCKit arm64 `0x1de6c`,
  ///    MobileVLCKit arm64 `0x20be8`) shows both calling
  ///    `libvlc_media_get_tracks_info` and reading the video union out of a
  ///    28-byte `libvlc_media_track_info_t`, a struct whose header has no
  ///    orientation member at all.
  ///  * Android's is `mediaPlayer.currentVideoTrack.width/height`. The class
  ///    it reads (`IMedia.VideoTrack`) *does* carry a sibling `orientation`
  ///    field; the plugin does not read it.
  ///
  /// So a clip shot in portrait on a handset — stored as landscape frames plus
  /// a 90° rotation matrix, which is how every phone camera writes one — is
  /// reported as 1920x1080 and would turn the handset the wrong way, which is
  /// worse than the manual switch this replaced.
  ///
  /// `codedVideoSize` cannot lie about it. It is the width and height libVLC's
  /// `vmem` output hands the sink, and `vmem.c`'s `Open` runs
  /// `video_format_ApplyRotation` first (VLCKit arm64 `0x140b8e0`, immediately
  /// before the `blr` to our setup callback); the transposed orientations swap
  /// width and height there in a single `rev64.4s` at `0x8e050`. The buffer is
  /// the upright picture, so its shape is the picture's shape.
  ///
  /// The cost is that a backend with no texture reports no coded size, and
  /// then this pins **nothing** — see the class doc on the screen's
  /// `_syncOrientation` for which backends those are and why leaving the
  /// device alone is the right answer there.
  ///
  /// ## The settle
  ///
  /// A shape has to hold for [shapeSettleDelay] before it is believed. libVLC
  /// revises the track it reports during startup, and acting on the first
  /// reading meant a handset that physically rotated and then rotated again a
  /// beat later. Waiting on a clock rather than counting readings is what
  /// makes it work for an engine that reports a shape correctly *once* and
  /// then goes quiet — see [shapeSettleDelay].
  ///
  /// Two more gates:
  ///
  ///  * An unknown size — null or zero, which is what every `setMedia`
  ///    produces while the state is `opening` — drops the candidate so the
  ///    next media settles on its own readings, and leaves [_pinnedOrientation]
  ///    alone so the device does not swing back to the browse orientation in
  ///    the gap between two episodes.
  ///  * Only a *changed* verdict is sent. A resolution change inside one
  ///    landscape film — an HLS variant switch, a failover to another source —
  ///    is the same verdict and must not become another platform message.
  ///
  /// ## What this does to an OS rotation lock
  ///
  /// It overrides it, and it did so before this settle existed too. Flutter's
  /// `setPreferredOrientations` becomes `setRequestedOrientation` on Android
  /// and the supported-orientations mask on iOS, and both outrank the user's
  /// rotation lock. Nothing detects that lock: iOS exposes no public API for
  /// it at all, and Android's `Settings.System.ACCELEROMETER_ROTATION` is
  /// reachable only through a native channel this app does not have.
  ///
  /// Two things keep it as small as it can be. The pin is always a *pair*, so
  /// the viewer can still turn the handset end for end, and it is scoped to
  /// the player route and undone by [restoreOrientation]. And it is now only
  /// ever issued from a measurement that knows which way up the picture is:
  /// the player will decline to rotate a device rather than rotate it on a
  /// guess.
  void applyVideoOrientation(
    PlayerFormFactor form, {
    required Size? renderedSize,
  }) {
    // Dropped rather than merely ignored: full screen mode can turn a phone
    // into a `tv` between two ticks, and a candidate armed a moment earlier
    // must not go on to rotate a television.
    if (!form.pinsOrientation) return _dropShapeCandidate();
    if (renderedSize == null ||
        renderedSize.width <= 0 ||
        renderedSize.height <= 0) {
      return _dropShapeCandidate();
    }
    // Square counts as landscape: a 1:1 clip fits either way, and landscape is
    // where the controls have room. That absorbs the one imprecision in using
    // a decoder buffer as the measurement - the buffer is padded up to a
    // multiple of sixteen, so a picture within fifteen rows of square can be
    // rounded across the line. A 1080x1088 video is square to a viewer, and
    // either verdict serves it.
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
  /// Phones return to [DeviceOrientation.portraitUp], the browse UI's only
  /// sensible shape; anything else is released with an empty list, which means
  /// "whatever the manifest and Info.plist already allow". Restoring
  /// `DeviceOrientation.values` instead — as the screen once did — unlocks
  /// rotation app-wide and leaves every other screen free to land sideways.
  ///
  /// Gated on [_pinnedOrientation] rather than on the form factor, which is the
  /// fix for a real trap: a player closed before the first frame decoded — a
  /// stream that would not resolve, a viewer who changed their mind — pinned
  /// nothing on the way in, and pinning `portraitUp` on the way out froze
  /// rotation for the rest of the process, since nothing else in the app ever
  /// calls `setPreferredOrientations`. The flag is also the only honest record
  /// of it: the form factor can have changed underneath us since the pin.
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
