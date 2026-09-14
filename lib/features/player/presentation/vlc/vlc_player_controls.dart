import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vlc_player/vlc_player.dart';

import '../../../../core/providers/device_info_provider.dart';
import '../../../../core/models/torrent_status.dart';
import '../../../skip/data/skip_service.dart';
import '../../domain/skip_segments.dart';
import '../player_platform_service.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../widgets/hotstar_player_style.dart';
import '../widgets/player_control_components.dart';
import '../widgets/player_stream_widgets.dart' show PlayerBufferingIndicator;
import 'package:screen_brightness/screen_brightness.dart';

import 'chrome_visibility_controller.dart';
import 'player_rail.dart';
import 'player_value_selector.dart';
import 'transient_overlay.dart';
import 'vlc_progress_bar.dart';
import '../components/torrent_info_widget.dart';
import 'panel/player_panel.dart' show PlayerPanelTab;
import '../../../settings/presentation/player_settings_provider.dart';

/// Chrome for the VLC engine.
///
/// The design is shared with the media_kit overlay: [PlayerTopBar],
/// [PlayerBottomBar], [PlayerIconButton] and the scrubber are the same
/// widgets, so a design change lands on both paths at once.
///
/// [ChromeVisibilityController] owns the auto-hide timer; nothing here starts
/// or cancels one. The controls are ordinary focusable widgets in reading
/// order inside one FocusTraversalGroup and native traversal moves between
/// them; the three nodes this State owns route nothing. Position is consumed
/// inside [VlcProgressBar], so a tick rebuilds the scrubber and nothing else.
///
/// On macOS and iOS this chrome sits over a platform view, not a texture.
/// Flutter backs every layer over a platform view with its own IOSurface,
/// sized to the layer and rebuilt when the layer comes or goes, so a
/// window-sized opacity layer torn down on each hide produces black frames.
/// controls_layer_shape_test.dart holds the consequences: one setState per
/// user-visible mode change, a [RepaintBoundary] around anything drawn over
/// the video, no BackdropFilter or ImageFiltered over the video at all, and no
/// single opacity or filter layer spanning both bars - each bar fades on its
/// own so each layer is bar-sized.
///
/// The spinner keys on `isStalled || isBuffering`, never on the libVLC state
/// alone: only Android reports `buffering` mid-play, while VLCKit and the
/// desktop backends stay `playing` through a rebuffer.
///
/// Buttons whose backend does not exist here, or that the current device
/// cannot honour, are absent rather than disabled: the screen passes null for
/// anything unavailable. The five list buttons follow the same rule through
/// [panelTabs], so focus can never land on a control whose list does not
/// exist.
class VlcPlayerControls extends ConsumerStatefulWidget {
  const VlcPlayerControls({
    required this.controller,
    this.chrome,
    required this.title,
    this.subtitle,
    this.onBack,
    this.onNextEpisode,
    this.onOpenPanel,
    this.panelTabs = const <PlayerPanelTab>{
      PlayerPanelTab.audio,
      PlayerPanelTab.subtitles,
    },
    this.onEnterPip,
    this.fit = VlcVideoFit.contain,
    this.onFitChanged,
    this.onToggleFullscreen,
    this.isFullscreen = false,
    this.isLive = false,
    this.torrentStatus,
    this.skipSegments = const <SkipSegment>[],
    this.onSkipOutro,
    this.promptVisible = false,
    this.locked,
    super.key,
  });

  final VlcPlayerController controller;

  /// Whether the bars are up, when supplied by the screen.
  ///
  /// Two chrome decisions are the screen's: dropping the bars on Back before
  /// the route pops, since a pop under still-visible chrome flashes it over
  /// the exit, and holding them for as long as its panel is up. Both need a
  /// hand on the one controller, so the screen may own it and lend it here,
  /// and it outlives these controls across every failover and episode
  /// advance. Null keeps a private controller for the life of this State.
  final ChromeVisibilityController? chrome;

  final String title;
  final String? subtitle;
  final VoidCallback? onBack;

  /// Non-null only when a next episode exists.
  final VoidCallback? onNextEpisode;

  /// Opens the panel on [tab] and completes when it closes, so the chrome can
  /// be held for the panel's life and the button that opened it is still there
  /// to take focus back. Null when there is no panel to open, and then none of
  /// the five list buttons is rendered.
  final Future<void> Function(PlayerPanelTab tab)? onOpenPanel;

  /// The tabs the panel would show right now; a button is rendered only for a
  /// tab that exists. Audio and Subtitles are always present.
  final Set<PlayerPanelTab> panelTabs;

  /// Non-null only where picture-in-picture is actually available.
  final VoidCallback? onEnterPip;

  /// The current video fit. Owned by the screen, not here.
  ///
  /// These controls are rebuilt from scratch on every open attempt, so a fit
  /// kept in this State is reseeded from the settings default each time and
  /// throws away the viewer's zoom.
  final VlcVideoFit fit;

  /// Reported up so the screen can hand the same value to [VlcPlayer]: on the
  /// texture platforms its FittedBox is the only thing that can honour a fit,
  /// because the native setFit is a no-op there.
  final ValueChanged<VlcVideoFit>? onFitChanged;

  /// Desktop only; null elsewhere, where the window is already full screen.
  final VoidCallback? onToggleFullscreen;
  final bool isFullscreen;

  /// Whether this is a live stream, decided by the app rather than the engine.
  final bool isLive;

  /// Non-null only while a torrent is playing and being polled.
  final TorrentStatus? torrentStatus;

  /// Intro/outro bands, usually empty - both sources are opt-in.
  final List<SkipSegment> skipSegments;

  /// What "I am done with this episode" does, when an episode actually
  /// follows. Null on the last episode and on a film, where the chip falls
  /// back to its plain seek to the end of the credits.
  ///
  /// With this non-null the outro chip becomes Next and hands the decision to
  /// the screen, which raises the one up-next card the player already has: one
  /// countdown, one advance path, no second card to keep in step.
  final VoidCallback? onSkipOutro;

  /// Whether the screen has a prompt of its own in the bottom-right corner -
  /// the up-next card, or the ended card.
  ///
  /// The skip chip lives outside the chrome so it survives hidden bars, which
  /// also leaves it mounted, hit-testable and D-pad reachable underneath a
  /// card the screen paints after it. It is suppressed rather than re-ordered,
  /// because a scrim over it would be a window-sized effect layer this file
  /// forbids.
  final bool promptVisible;

  /// Whether the screen is locked against accidental touches, when the screen
  /// offers a lock at all.
  ///
  /// Non-null on a touch form factor and null everywhere else, so the lock is
  /// absent on a television and on a desktop by construction. See
  /// [_lockAvailable] for the second gate these controls apply on top.
  ///
  /// Screen-owned because Back is decided in the screen's `_handleBack`, which
  /// has to read this flag, and because it has to outlive these controls,
  /// which are rebuilt from scratch on every failover and episode advance.
  ///
  /// A [ValueNotifier] rather than a `bool` plus a callback for the same
  /// reason [chrome] is one: the padlock, the unlock chip, Back and every
  /// clear-the-lock path all write it, and none should own a setState.
  final ValueNotifier<bool>? locked;

  @override
  ConsumerState<VlcPlayerControls> createState() => _VlcPlayerControlsState();
}

/// How a relative seek reports itself.
///
/// A keypress or a D-pad burst has no side, so it keeps the centred pill every
/// other transient message uses. A double-tap does have one, and saying which
/// half fired is the point of the burst.
enum _SeekFeedback { toast, burst }

class _VlcPlayerControlsState extends ConsumerState<VlcPlayerControls> {
  static const Duration _fade = Duration(milliseconds: 200);

  /// How far in a Skip Outro press leaves the position before the advance it
  /// triggers is allowed to happen. Past `kCompletedFraction`
  /// (playback_progress.dart, 0.90) so the episode is recorded as watched, and
  /// short of the duration so the up-next card gets its countdown instead of
  /// being overtaken by end-of-media.
  static const double _outroAdvanceFraction = 0.95;

  /// Matches the viewer's seek duration setting.
  Duration get _seekStep => Duration(
    seconds: _seekStepSeconds(
      ref.read(playerSettingsProvider).asData?.value ?? const PlayerSettings(),
    ),
  );

  /// The configured step in whole seconds, with a 0-means-default guard. Taken
  /// off a [PlayerSettings] the caller already has, so the bar's two buttons
  /// and the seek they perform can never disagree about how far a press goes.
  static int _seekStepSeconds(PlayerSettings settings) =>
      settings.seekDuration > 0 ? settings.seekDuration : 10;

  /// The numbered glyph where Material has one for this step, and the plain
  /// replay/fast-forward pair where it does not - the picker also offers 15,
  /// 20, 60 and 120, and a `replay_10` on a 30 s step would lie.
  static IconData _stepIcon(int seconds, {required bool forward}) =>
      switch ((seconds, forward)) {
        (5, false) => Icons.replay_5_rounded,
        (10, false) => Icons.replay_10_rounded,
        (30, false) => Icons.replay_30_rounded,
        (5, true) => Icons.forward_5_rounded,
        (10, true) => Icons.forward_10_rounded,
        (30, true) => Icons.forward_30_rounded,
        (_, false) => Icons.replay_rounded,
        (_, true) => Icons.fast_forward_rounded,
      };

  /// What the button is called: "Rewind 30 seconds", "Forward 5 seconds".
  ///
  /// [Tooltip] republishes its message to the accessibility tree, so this one
  /// string is both the hover tooltip and the only name these two glyphs have
  /// anywhere. It says the action rather than a signed amount, which a screen
  /// reader read out as "minus 30 sec".
  ///
  /// [seconds] goes through the message rather than into it: the strings are
  /// ICU plurals, so a locale that inflects the noun after a numeral gets the
  /// form its own rule picks. Seconds at every step, including 60 and 120, so
  /// the tooltip agrees with the readout the press produces - [_seekBy]'s
  /// toast, the seek burst and the D-pad chain all count in seconds.
  static String _stepLabel(
    AppLocalizations l10n,
    int seconds, {
    required bool forward,
  }) => forward
      ? l10n.playerForwardSeconds(seconds)
      : l10n.playerRewindSeconds(seconds);

  /// Whether the player should wear its ten-foot clothes.
  ///
  /// Through [playerFormFactorOf], not the raw profile, so full screen mode on
  /// a desktop plugged into a television reaches the same verdict the screen
  /// reaches - otherwise the screen adopts the TV layout and the bar does not.
  bool get _isTv =>
      playerFormFactorOf(ref.read(deviceProfileProvider).asData?.value) ==
      PlayerFormFactor.tv;

  /// Desktop is whatever can toggle fullscreen: the screen passes it only
  /// where the window is not already full screen.
  bool get _isDesktop => widget.onToggleFullscreen != null;

  /// Whether the big centred play/pause is built at all: touch only.
  ///
  /// Television is excluded because Select already toggles playback and
  /// [_playPause] autofocuses; desktop because the pointer is precise and
  /// Space is right there.
  ///
  /// Deliberately not the build-local `isTouch`, which is
  /// `Platform.isAndroid || Platform.isIOS` and therefore false on every test
  /// host, so a glyph gated on it could not be tested at all.
  bool get _showCenterGlyph => !_isTv && !_isDesktop;

  /// Whether the device profile says this is a desktop operating system.
  ///
  /// Deliberately not [_isDesktop], which is only `onToggleFullscreen != null`.
  /// The two agree on every real device and disagree in a widget test, where
  /// dart:io reports the host, so every screen-level test on a Mac looks like
  /// a desktop no matter what profile it overrode. Anything a test has to be
  /// able to state comes from the profile.
  bool get _isDesktopProfile =>
      ref.read(deviceProfileProvider).asData?.value.isDesktopOS ?? false;

  /// Whether this build has a lock to offer at all.
  ///
  /// Two independent gates: the screen passes [VlcPlayerControls.locked] only
  /// on a touch form factor, and this refuses on top of that, so a caller that
  /// hands one in anyway still gets no padlock and no chip.
  ///
  /// It does not matter that this and [_showCenterGlyph] can disagree on a
  /// test host: locking withholds the glyph unconditionally.
  bool get _lockAvailable =>
      widget.locked != null && !_isTv && !_isDesktopProfile;

  /// Whether the AudioVolumeUp/Down keys are this app's to claim. Only a
  /// desktop keyboard's are.
  ///
  /// On Android the same logical key is the hardware rocker, and the embedder
  /// gives the framework first refusal: FlutterView.dispatchKeyEvent returns
  /// true the moment the framework says handled, so the DecorView,
  /// PhoneWindow's volume fallback and the system HUD never run. Returning
  /// ignored is what sends the press back out. iOS never delivers the buttons
  /// to an app at all; on TV, volume belongs to the television or the AVR.
  ///
  /// Read through [defaultTargetPlatform], not dart:io: it is the real
  /// platform in production and the only one a widget test can state. It is
  /// deliberately not [_isDesktop], which is merely
  /// `onToggleFullscreen != null`.
  static bool get _ownsVolumeKeys => switch (defaultTargetPlatform) {
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
    _ => false,
  };

  /// Whether the bars are up, their timer and their holds. This State only
  /// listens - one setState per change - and nothing else here may decide when
  /// the chrome goes. Every reference goes through here, so the lent and the
  /// private controller are indistinguishable below this line.
  ChromeVisibilityController get _chrome => widget.chrome ?? _ownChrome!;

  /// Built only when the screen lends nothing, and the only one this State
  /// disposes.
  ChromeVisibilityController? _ownChrome;

  /// Where keys land when no control has focus. Never a traversal candidate,
  /// so no arrow can pick it, and focused whenever nothing else is - see
  /// [_claimLooseFocus].
  final FocusNode _sink = FocusNode(
    debugLabel: 'player-key-sink',
    skipTraversal: true,
  );

  /// Root of the focusable chrome. It cannot take focus itself, so its
  /// `hasFocus` means exactly "a control is focused", and flipping
  /// descendantsAreFocusable on it is what ExcludeFocus does, on a node this
  /// State can ask.
  final FocusNode _chromeRoot = FocusNode(
    debugLabel: 'player-chrome',
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// Where the D-pad starts and, with nowhere better, returns to.
  final FocusNode _playPause = FocusNode(debugLabel: 'player-play-pause');

  /// The skip chip's node, owned here rather than left to the button.
  ///
  /// The chip is the one control outside the chrome, so [_restoreChromeFocus]
  /// has to be able to ask by name whether it holds focus and leave the remote
  /// alone if it does.
  ///
  /// Where the remote goes when the chip vanishes needs nothing here: the
  /// framework detaches the node with
  /// `UnfocusDisposition.previouslyFocusedChild`.
  final FocusNode _skipFocus = FocusNode(debugLabel: 'player-skip-chip');

  /// The control that had focus when the bars went down. The scope forgets
  /// it - a node that becomes unfocusable is dropped from its history - so
  /// bringing the remote back where it was needs this.
  FocusNode? _focusBeforeHide;

  /// So an overlay animating under a stationary cursor is not activity.
  Offset? _hoverAt;

  /// A brief centred message - the resize mode, seek and speed. Written from
  /// every swipe-seek update, so it is a notifier rather than a field.
  final TransientValue<String> _toast = TransientValue<String>();

  /// The double-tap seek readout, on the half of the screen that was tapped.
  ///
  /// Its own notifier rather than a second meaning for [_toast]: the two are
  /// different shapes in different places, and a press must be able to replace
  /// a toast a swipe left behind, and the other way round.
  final TransientValue<SeekBurst> _burst = TransientValue<SeekBurst>();

  /// Bumped on every burst so a second tap in the same direction, with the
  /// same cumulative total, still replays the ripple. See [SeekBurst.revision].
  int _burstRevision = 0;

  /// Torrent statistics are opt-in: useful when a stream is struggling,
  /// clutter the rest of the time.
  bool _showTorrentInfo = false;

  /// Maximum volume boost from player settings (100–200%).
  int get _maxVolume {
    final v =
        ref.read(playerSettingsProvider).asData?.value.maxVolumePercent ?? 200;
    return v.clamp(100, 200);
  }

  /// Which rail a vertical drag is driving, and the value it started from.
  /// Null when no drag is in progress.
  bool? _dragIsVolume;
  double _dragStart = 0;

  /// Mirrored so the rail can render without awaiting the platform on each
  /// frame. Brightness is an OS control; libVLC has no equivalent.
  double _brightness = 0.5;

  /// Whether this session actually changed the application brightness, so
  /// teardown only resets an override it created.
  bool _brightnessOverridden = false;

  /// The volume / brightness rail. Written on every drag update, same rule as
  /// [_toast]. Holds the [PlayerRail] itself; the gesture, the engine call and
  /// the timer stay on this side.
  final TransientValue<PlayerRail> _rail = TransientValue<PlayerRail>();

  /// Horizontal drag seek state.
  double? _horizontalDragStartX;
  Duration? _horizontalDragStartPosition;
  Duration? _horizontalDragTarget;

  /// Where the next relative seek counts from while the engine has not yet
  /// published the last one. Without it a second press before the engine's
  /// read-back arrives starts from the stale position and undoes the first.
  /// Same window as the progress bar's latch, so the two agree on when the
  /// controller is the truth again.
  Duration? _seekBase;

  /// The published position the current chain started from, for the toast.
  Duration? _seekOrigin;
  Timer? _seekBaseReset;

  /// The controller the progress bar's drag or D-pad burst is holding up, if
  /// one is.
  ///
  /// The hold is counted and [ChromeVisibilityController.release] is the only
  /// thing that gives one back, so an unmatched hold pins the bars up for the
  /// rest of the session. Keeping it here makes the pair idempotent, lets
  /// [dispose] give back a hold whose end never came, and gives it back to the
  /// controller that took it even if the screen swapped controllers mid-drag.
  ChromeVisibilityController? _seekChromeHold;

  /// Speed to restore when a long-press boost ends. Null when not boosting.
  double? _speedBeforeBoost;

  /// Whether a bare Space is down and this widget has claimed the press.
  ///
  /// The keyboard's half of hold-to-2x. Set only on a press this file would
  /// have acted on anyway - nothing focused - so a Space aimed at a focused
  /// button is never claimed here, and neither is its repeat or its release.
  /// See [_handleKey] for why the toggle waits for the release.
  bool _spaceHeld = false;

  bool _appliedInitialFit = false;

  @override
  void initState() {
    super.initState();
    // Defer setFit until the controller is attached to the native player view
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applyFit(widget.fit);
    });

    widget.controller.addListener(_onControllerValue);
    if (widget.chrome == null) {
      _ownChrome = ChromeVisibilityController(
        isPlaying: () => widget.controller.value.isPlaying,
      );
    }
    _chrome.addListener(_onChromeChanged);
    FocusManager.instance.addListener(_claimLooseFocus);
    // The listener only fires on a change. Coming from the resolving stage the
    // scope is parked before this widget has a node to offer, and nothing
    // changes afterwards to wake the listener, so claim it once on arrival.
    WidgetsBinding.instance.addPostFrameCallback((_) => _claimLooseFocus());
  }

  @override
  void didUpdateWidget(VlcPlayerControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chrome == widget.chrome) return;
    // The screen swapped or withdrew its controller mid-life. Follow the new
    // one, and if it withdrew, fall back to a private one so nothing here ever
    // has no controller to listen to.
    (oldWidget.chrome ?? _ownChrome)?.removeListener(_onChromeChanged);
    if (widget.chrome == null && _ownChrome == null) {
      _ownChrome = ChromeVisibilityController(
        isPlaying: () => widget.controller.value.isPlaying,
      );
    }
    _chrome.addListener(_onChromeChanged);
    setState(() {});
  }

  void _onControllerValue() {
    if (!_appliedInitialFit && widget.controller.value.isPlaying) {
      _appliedInitialFit = true;
      _applyFit(widget.fit);
    }
  }

  Future<void> _applyFit(VlcVideoFit fit) async {
    try {
      await widget.controller.setFit(fit);
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to setFit: $e');
    }
  }

  @override
  void dispose() {
    // Application brightness is a process-wide override, so leaving the
    // player without clearing it dims the whole app until the process dies.
    if (_brightnessOverridden) {
      unawaited(
        ScreenBrightness().resetApplicationScreenBrightness().catchError(
          (_) {},
        ),
      );
    }
    widget.controller.removeListener(_onControllerValue);
    FocusManager.instance.removeListener(_claimLooseFocus);
    // A drag or a D-pad burst still in flight when the player goes away never
    // gets its end, and the chrome usually outlives this State, so an
    // unreleased hold would follow it into the next media and pin those bars
    // up. Before _ownChrome is disposed, so the private controller re-arms
    // rather than being written to dead.
    _endSeekHold(null);
    // Same rule: a boost is a hold on the controller, which outlives these
    // controls, so a press still down when the player goes would start the
    // next media at 2x. Before [_toast] is disposed, since ending a boost
    // clears it.
    try {
      _endSpeedBoost();
    } catch (e) {
      // A boost that spanned a controller swap has nothing left to give the
      // speed back to: the engine call asserts on a disposed controller, and an
      // exception thrown out of dispose takes the route with it.
      if (kDebugMode) debugPrint('Failed to end speed boost: $e');
    }
    _chrome.removeListener(_onChromeChanged);
    _seekBaseReset?.cancel();
    _ownChrome?.dispose();
    _sink.dispose();
    _chromeRoot.dispose();
    _playPause.dispose();
    _skipFocus.dispose();
    _toast.dispose();
    _burst.dispose();
    _rail.dispose();
    super.dispose();
  }

  /// One setState per visibility change, plus the focus bookkeeping that
  /// ExcludeFocus does not do: it drops focus when it starts excluding and
  /// hands nothing back when it stops.
  void _onChromeChanged() {
    if (_chrome.value) {
      // The controls are focusable again only after the frame that flips
      // descendantsAreFocusable has built; a request before that is refused.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _restoreChromeFocus(),
      );
    } else if (_chromeRoot.hasFocus) {
      _focusBeforeHide = FocusManager.instance.primaryFocus;
    }
    setState(() {});
  }

  /// Brings the remote back where it was when the bars went down.
  ///
  /// Focus alone does not hold the chrome up: on a television it is always on
  /// some control while the bars show, so that rule would mean they never
  /// hide. On TV there is always somewhere to go, play/pause if nothing
  /// better, because focus is the pointer there. On a keyboard the sink keeps
  /// it, so arrows go on seeking rather than walking the button row.
  ///
  /// [_skipFocus] bails out because the skip chip is outside the chrome: the
  /// poke that reveals the bars would otherwise move focus to play/pause a
  /// frame later, and a Select aimed at Skip would pause the film.
  void _restoreChromeFocus() {
    if (!mounted || !_chrome.value || _chromeRoot.hasFocus) return;
    if (_skipFocus.hasFocus) return;
    final previous = _focusBeforeHide;
    _focusBeforeHide = null;
    // Liveness has to be read from the focus tree, not from `context`: the SDK
    // assigns FocusNode._context on attach and never clears it, so a node whose
    // element has been unmounted still answers non-null and then swallows
    // requestFocus(). A detached node has no enclosing scope. It matters
    // per-episode: rebuilding the action list can unmount the remembered
    // button.
    final revivable = previous != null && previous.enclosingScope != null;
    final target = revivable ? previous : (_isTv ? _playPause : null);
    target?.requestFocus();
  }

  /// A scope above the sink holding primary focus means nothing beneath it
  /// does. That is what hiding leaves behind when a control was focused, and
  /// what a sheet leaves behind when it closes over chrome that hid under it;
  /// either way the next arrow would be spent re-focusing the scope. The sink
  /// takes it instead, so every key still reaches [_handleKey].
  void _claimLooseFocus() {
    final primary = FocusManager.instance.primaryFocus;
    if (primary is FocusScopeNode &&
        _sink.ancestors.contains(primary) &&
        _sink.canRequestFocus) {
      _sink.requestFocus();
    }
  }

  void _showToast(String message) =>
      _toast.show(message, hideAfter: const Duration(milliseconds: 900));

  /// Holds playback at double speed while the finger is down.
  ///
  /// Live streams are excluded: there is nothing ahead to race towards, and
  /// libVLC will simply drift off the live edge.
  void _startSpeedBoost() {
    if (widget.isLive || _speedBeforeBoost != null) return;
    final value = widget.controller.value;
    if (!value.isPlaying) return;
    _speedBeforeBoost = value.playbackSpeed;
    widget.controller.setPlaybackSpeed(2.0);
    _showToast('2x');
  }

  void _endSpeedBoost() {
    final previous = _speedBeforeBoost;
    if (previous == null) return;
    _speedBeforeBoost = null;
    widget.controller.setPlaybackSpeed(previous);
    _toast.clear();
  }

  /// Seeks by a fixed step, forward or back depending on which half was tapped.
  ///
  /// The only caller that asks for [_SeekFeedback.burst]: J/L, the D-pad and
  /// the skip chip keep the centred pill, because none of them is aimed at one
  /// half of the screen.
  void _doubleTapSeek(double dx) {
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    _seekBy(
      dx >= width / 2 ? _seekStep : -_seekStep,
      feedback: _SeekFeedback.burst,
    );
    _chrome.keepAlive();
  }

  /// Trims a speed to the shortest exact label: 1, 1.5, 1.25.
  static String _formatSpeed(double speed) {
    final text = speed.toStringAsFixed(2);
    return text.endsWith('00')
        ? text.substring(0, text.length - 3)
        : (text.endsWith('0') ? text.substring(0, text.length - 1) : text);
  }

  /// Whether a button for [tab] is rendered: there is a panel to open and the
  /// panel would show that tab.
  bool _hasPanelTab(PlayerPanelTab tab) =>
      widget.onOpenPanel != null && widget.panelTabs.contains(tab);

  /// Opens the panel on [tab], holding the chrome until it closes.
  void _open(PlayerPanelTab tab) =>
      unawaited(_chrome.whileHeld(() => widget.onOpenPanel!(tab)));

  /// Playback speed, applied instantly and not persisted.
  ///
  /// Deliberately session-scoped: a speed chosen for one talky episode should
  /// not silently apply to the next film.
  ///
  /// A Material sheet rather than a panel tab: seven rows with one current
  /// value, and nothing else in the panel to compare them against.
  Future<void> _pickSpeed() async {
    const speeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    final current = widget.controller.value.playbackSpeed;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF141414),
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final speed in speeds)
              ListTile(
                dense: true,
                // A remote opens onto the current value, not onto nothing.
                autofocus: _isTv && (speed - current).abs() < 0.01,
                selected: (speed - current).abs() < 0.01,
                selectedColor: Colors.white,
                leading: Icon(
                  (speed - current).abs() < 0.01
                      ? Icons.check_rounded
                      : Icons.speed,
                  color: Colors.white70,
                ),
                title: Text(
                  speed == 1.0
                      ? AppLocalizations.of(context)!.playerSpeedNormal
                      : '${_formatSpeed(speed)}x',
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  widget.controller.setPlaybackSpeed(speed);
                  _showToast('${_formatSpeed(speed)}x');
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Volume to restore when unmuting: the last non-zero level actually
  /// applied, by whichever route applied it. Written in [_setVolume] rather
  /// than in the M branch, because a level set by the rail drag or by a
  /// keyboard step is exactly the level a mute has to come back to.
  int? _volumeBeforeMute;

  /// The level last asked of the engine. The snapshot that reports a volume
  /// back arrives a platform round trip later - and on Android it is the
  /// pre-duck level, not the audible one - so the steps and the mute toggle
  /// count from what was applied, not from what has been reported.
  int? _appliedVolume;

  /// What the next step or toggle counts from: this widget's own last word,
  /// falling back to the engine's before it has said anything.
  int get _volume => _appliedVolume ?? widget.controller.value.volume;

  /// 5%, matching every mainstream keyboard player. Volume is a keyboard
  /// affordance only - see [_ownsVolumeKeys] for who gets the hardware keys.
  static const int _volumeStep = 5;

  void _nudgeVolume(int delta) => _setVolume(_volume + delta);

  /// Applies a volume and shows the same rail the drag gesture uses, so the
  /// two routes give identical feedback. [hideAfter] is null while a finger
  /// is on the rail: there the drag decides when it goes.
  void _setVolume(
    int volume, {
    Duration? hideAfter = const Duration(milliseconds: 900),
  }) {
    final clamped = volume.clamp(0, _maxVolume);
    _appliedVolume = clamped;
    // Zero is the mute, never a level to come back to.
    if (clamped != 0) _volumeBeforeMute = clamped;
    widget.controller.setVolume(clamped);
    _rail.show(
      PlayerRail(
        icon: clamped == 0
            ? Icons.volume_off_rounded
            : (clamped > 100
                  ? Icons.volume_up_rounded
                  : Icons.volume_down_rounded),
        value: clamped / _maxVolume,
        label: '$clamped%',
        onLeft: false,
      ),
      hideAfter: hideAfter,
    );
  }

  /// The gap between rows of [_pickVolume], and deliberately not
  /// [_volumeStep].
  ///
  /// A keyboard repeats, so 5% steps are a held key; a remote does not, and 41
  /// rows would be 41 presses. 20% keeps the whole range including the boost
  /// to one short list that fits a sheet without scrolling, which matters
  /// because the autofocus below is the only thing putting the remote on the
  /// current value.
  static const int _volumePickerStep = 20;

  /// The volume affordance a remote can reach.
  ///
  /// Every other route into the player's own gain needs hardware a sofa does
  /// not have: the AudioVolumeUp/Down keys are claimed on desktop only (see
  /// [_ownsVolumeKeys]), the bare Up/Down arrows are spent revealing the
  /// chrome on television, M is a keyboard key and the rail is a drag. Ranged
  /// over [_maxVolume] rather than 100, so the boost is reachable.
  Future<void> _pickVolume() async {
    final int max = _maxVolume;
    final levels = <int>[
      for (var level = 0; level <= max; level += _volumePickerStep) level,
    ];
    // A max that is not a multiple of the step would otherwise be the one
    // level the picker could not reach.
    if (levels.last != max) levels.add(max);
    final current = _volume;
    // Marked by proximity, not equality: the keyboard steps 5% at a time and
    // the rail lands anywhere at all, so the level in force is usually between
    // two rows.
    final selected = levels.reduce(
      (a, b) => (a - current).abs() <= (b - current).abs() ? a : b,
    );
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF141414),
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final level in levels)
              ListTile(
                dense: true,
                autofocus: _isTv && level == selected,
                selected: level == selected,
                selectedColor: Colors.white,
                leading: Icon(
                  level == selected
                      ? Icons.check_rounded
                      : (level == 0
                            ? Icons.volume_off_rounded
                            : (level > 100
                                  ? Icons.volume_up_rounded
                                  : Icons.volume_down_rounded)),
                  color: Colors.white70,
                ),
                title: Text(
                  '$level%',
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  // The same apply every other route uses, so the rail shows
                  // and the mute memory is written here too.
                  _setVolume(level);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Starts a brightness or volume drag based on user gesture configuration.
  Future<void> _railDragStart(DragStartDetails d) async {
    if (_isDesktop) return; // no touch rails
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    final isRight = d.localPosition.dx >= width / 2;
    final settings =
        ref.read(playerSettingsProvider).asData?.value ??
        const PlayerSettings();
    final gesture = isRight ? settings.rightGesture : settings.leftGesture;
    if (gesture == PlayerGesture.none) {
      _dragIsVolume = null;
      return;
    }
    final isVolume = gesture == PlayerGesture.volume;
    _dragIsVolume = isVolume;
    if (isVolume) {
      _dragStart = _volume.toDouble();
    } else {
      try {
        _brightness = await ScreenBrightness().application;
      } catch (_) {
        // Unsupported on this platform; carry on from the mirrored value.
      }
      _dragStart = _brightness;
    }
  }

  void _onHorizontalDragStart(DragStartDetails d, PlayerSettings settings) {
    // An unseekable input gets no start position, so the updates show no
    // toast and the end issues no seekTo that libVLC would silently drop.
    if (widget.isLive ||
        _isDesktop ||
        !settings.swipeSeekEnabled ||
        !widget.controller.value.isSeekable) {
      return;
    }
    _horizontalDragStartX = d.globalPosition.dx;
    _horizontalDragStartPosition = widget.controller.value.position;
    _horizontalDragTarget = _horizontalDragStartPosition;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails d, PlayerSettings settings) {
    final startX = _horizontalDragStartX;
    final startPos = _horizontalDragStartPosition;
    if (startX == null || startPos == null || !settings.swipeSeekEnabled) {
      return;
    }
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0) return;
    final deltaFraction = (d.globalPosition.dx - startX) / width;
    final duration = widget.controller.value.duration;
    final seekDelta = Duration(milliseconds: (deltaFraction * 90000).round());
    var target = startPos + seekDelta;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    _horizontalDragTarget = target;
    final diffSeconds = (target - startPos).inSeconds;
    _showToast(
      diffSeconds < 0
          ? '${diffSeconds}s (${_formatDuration(target)})'
          : '+${diffSeconds}s (${_formatDuration(target)})',
    );
  }

  void _onHorizontalDragEnd(DragEndDetails d) {
    final target = _horizontalDragTarget;
    _horizontalDragStartX = null;
    _horizontalDragStartPosition = null;
    _horizontalDragTarget = null;
    if (target != null) {
      widget.controller.seekTo(target);
      _rebaseSeekChain(target);
      _chrome.keepAlive();
    }
  }

  static String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  /// A full screen height of travel covers the whole range.
  void _railDragUpdate(DragUpdateDetails d) {
    final isVolume = _dragIsVolume;
    if (isVolume == null) return;
    final height = context.size?.height ?? 0;
    if (height <= 0) return;

    final travel = -d.primaryDelta! / height;
    if (isVolume) {
      _dragStart = (_dragStart + travel * _maxVolume).clamp(
        0.0,
        _maxVolume * 1.0,
      );
      // The same apply the keyboard uses, so the finger's level is remembered
      // for the mute toggle too. No hideAfter: the rail stays until the drag
      // ends and _railDragEnd starts the clock.
      _setVolume(_dragStart.round(), hideAfter: null);
    } else {
      _dragStart = (_dragStart + travel).clamp(0.0, 1.0);
      _brightness = _dragStart;
      _brightnessOverridden = true;
      unawaited(
        ScreenBrightness()
            .setApplicationScreenBrightness(_brightness)
            .catchError((_) {}),
      );
      _rail.show(
        PlayerRail(
          icon: Icons.brightness_6_rounded,
          value: _brightness,
          label: '${(_brightness * 100).round()}%',
        ),
      );
    }
  }

  void _railDragEnd() {
    _dragIsVolume = null;
    _rail.clearAfter(const Duration(milliseconds: 500));
  }

  /// Keyboard and remote shortcuts.
  ///
  /// [_handleKey] returns ignored for anything it does not claim, so
  /// directional keys keep reaching the focus system and native traversal
  /// moves between controls. Only keys with no traversal meaning are handled.
  static bool _isDirectional(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.arrowUp ||
      key == LogicalKeyboardKey.arrowDown ||
      key == LogicalKeyboardKey.arrowLeft ||
      key == LogicalKeyboardKey.arrowRight;

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    // Hold-to-2x needs the whole press rather than its leading edge, so the
    // repeat and the release are read before the down-only fast path. Both are
    // gated on [_spaceHeld], which is set only by a Space this file already
    // claimed, so every other key is seen once, on the way down.
    if (event is KeyRepeatEvent) {
      if (!_spaceHeld || event.logicalKey != LogicalKeyboardKey.space) {
        return KeyEventResult.ignored;
      }
      // A key still down is still interaction, so the bars stay up for the
      // life of the boost. [_startSpeedBoost] is idempotent, so every further
      // repeat is a poke and nothing else.
      _chrome.poke();
      _startSpeedBoost();
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      if (!_spaceHeld || event.logicalKey != LogicalKeyboardKey.space) {
        return KeyEventResult.ignored;
      }
      _spaceHeld = false;
      // A hold ends by giving the speed back. A tap - a press that never
      // repeated - is the play/pause toggle the down press deferred.
      if (_speedBeforeBoost != null) {
        _endSpeedBoost();
      } else {
        _togglePlayback();
      }
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // Back is not ours, and must not poke. Android delivers it as this key
    // first and as popRoute second; the screen's _handleBack decides between
    // hiding the bars and leaving based on whether the bars were already up,
    // so a poke here would flash the bars on every Back press and the player
    // could never be left while playing.
    if (event.logicalKey == LogicalKeyboardKey.goBack) {
      return KeyEventResult.ignored;
    }

    // Any other key keeps the chrome alive, and summons it when hidden - on a
    // remote there is no tap to reveal it with. Focus is restored after the
    // frame, so the key doing the summoning is judged against where focus was.
    _chrome.poke();

    // Arrows are shortcuts only while the sink itself holds focus, which is to
    // say nothing else in the player does. With a control focused they are
    // traversal and belong to the focus system.
    final bare = node.hasPrimaryFocus;

    final key = event.logicalKey;

    // A bare arrow is a keyboard idiom - volume and seek with nothing focused.
    // On a remote, bare means the bars are down, so the same press is the one
    // summoning them, and firing volume or a seek off it would make waking the
    // chrome destructive. The press is spent revealing the bars instead.
    if (bare && _isTv && _isDirectional(key)) return KeyEventResult.handled;
    // K and the media keys have no activation meaning, so they stay global.
    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.keyK) {
      _togglePlayback();
      return KeyEventResult.handled;
    }
    // Space is the activation key for whatever is focused, so it is a shortcut
    // only while nothing is: claimed with a button focused it would toggle
    // playback instead of pressing the button.
    //
    // A bare Space is two shortcuts on one key - tap toggles, hold runs at 2x -
    // and only the release tells them apart, so the down press claims the key
    // and does nothing else. Toggling on the leading edge instead would pause
    // the film under a viewer who meant to skim.
    if (bare && key == LogicalKeyboardKey.space) {
      _spaceHeld = true;
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlay) {
      widget.controller.play();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPause) {
      widget.controller.pause();
      return KeyEventResult.handled;
    }
    // LB/RB, alongside J/L and through the same [_seekBy], so a pad inherits
    // the chain window and the toast rather than growing a second seek path.
    //
    // A shoulder button has no traversal meaning and no activation meaning, so
    // unlike the arrows and unlike Space it needs no `bare` guard and is not
    // spent revealing the chrome on television: the press that wakes the bars
    // also seeks, exactly as J and L do.
    if (key == LogicalKeyboardKey.keyJ ||
        key == LogicalKeyboardKey.gameButtonLeft1) {
      _seekBy(-_seekStep);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyL ||
        key == LogicalKeyboardKey.gameButtonRight1) {
      _seekBy(_seekStep);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF && widget.onToggleFullscreen != null) {
      widget.onToggleFullscreen!.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape &&
        widget.isFullscreen &&
        widget.onToggleFullscreen != null) {
      widget.onToggleFullscreen!.call();
      return KeyEventResult.handled;
    }

    // The rocker is the phone's, not ours: off desktop this must fall through
    // as ignored or the handset's own volume never moves and its HUD never
    // appears, while the app walks its private libVLC gain. See
    // [_ownsVolumeKeys] for the embedder path behind that.
    if (key == LogicalKeyboardKey.audioVolumeUp ||
        key == LogicalKeyboardKey.audioVolumeDown) {
      if (!_ownsVolumeKeys) return KeyEventResult.ignored;
      _nudgeVolume(
        key == LogicalKeyboardKey.audioVolumeUp ? _volumeStep : -_volumeStep,
      );
      return KeyEventResult.handled;
    }
    // A bare arrow is the keyboard idiom, not a hardware key, and on TV it
    // never reaches here - the directional guard above already spent it.
    if (bare &&
        (key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown)) {
      _nudgeVolume(
        key == LogicalKeyboardKey.arrowUp ? _volumeStep : -_volumeStep,
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM) {
      final current = _volume;
      if (current == 0) {
        _setVolume(_volumeBeforeMute ?? 100);
      } else {
        // Also covers a level this widget never applied - the engine's own
        // starting volume - which _setVolume has had no chance to record.
        _volumeBeforeMute = current;
        _setVolume(0);
      }
      return KeyEventResult.handled;
    }

    if (bare) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        _seekBy(-_seekStep);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        _seekBy(_seekStep);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  /// Play or pause, read exactly as the glyph reads it: a rebuffer is still
  /// playback, so the key does what the button shows.
  void _togglePlayback() {
    final running = widget.controller.value;
    running.isPlaying || running.isBuffering
        ? widget.controller.pause()
        : widget.controller.play();
  }

  /// Seeks relative to the current position, clamped at both ends because
  /// seekTo rejects a negative position and overshooting the end would trip the
  /// end-of-media handler.
  ///
  /// Presses within [_seekBase]'s window chain: the second step counts from
  /// the first target, not from the position the engine last published, and
  /// the toast shows the offset of the whole chain. The window is the one the
  /// progress bar latches its thumb for, and it is longer than the
  /// controller's stall delay on purpose - a chain the engine is slow to
  /// honour gets its spinner before the base falls back to the truth.
  ///
  /// [feedback] picks how the step is shown and changes nothing else.
  void _seekBy(Duration delta, {_SeekFeedback feedback = _SeekFeedback.toast}) {
    final value = widget.controller.value;
    if (widget.isLive || !value.isSeekable) return;
    final origin = _seekBase == null ? value.position : _seekOrigin!;
    var target = (_seekBase ?? value.position) + delta;
    if (target < Duration.zero) target = Duration.zero;
    final duration = value.duration;
    if (duration > Duration.zero && target > duration) target = duration;
    _seekBase = target;
    _seekOrigin = origin;
    _armSeekBaseReset();
    widget.controller.seekTo(target);
    final offset = target - origin;
    switch (feedback) {
      case _SeekFeedback.toast:
        _showToast(
          offset.isNegative
              ? '-${(-offset).inSeconds}s'
              : '+${offset.inSeconds}s',
        );
      case _SeekFeedback.burst:
        _showSeekBurst(delta, offset);
    }
  }

  /// The side is [delta]'s - which half the viewer actually tapped - and the
  /// number is the chain's cumulative [offset] measured in that same
  /// direction. Where a reversal has carried the chain back past its origin
  /// the number goes negative and says so.
  void _showSeekBurst(Duration delta, Duration offset) {
    final bool forward = !delta.isNegative;
    _burstRevision++;
    _burst.show(
      SeekBurst(
        forward: forward,
        seconds: (forward ? offset : -offset).inSeconds,
        revision: _burstRevision,
      ),
      hideAfter: const Duration(milliseconds: 900),
    );
  }

  /// Adopts [target] as the position the next relative step counts from.
  ///
  /// Every absolute seek the controls can see - a scrubber drag, a track tap,
  /// a swipe release, the skip button - moves playback somewhere [_seekBase]
  /// knows nothing about, and the engine will not publish it for a round trip,
  /// so the next arrow would count from a stale position. The seek that just
  /// happened is the truth, so it becomes the base.
  void _rebaseSeekChain(Duration target) {
    _seekBase = target;
    _seekOrigin = target;
    _armSeekBaseReset();
  }

  /// One window for the whole chain, restarted by every seek that feeds it.
  void _armSeekBaseReset() {
    _seekBaseReset?.cancel();
    _seekBaseReset = Timer(
      widget.controller.stallIndicatorDelay + const Duration(milliseconds: 500),
      () {
        _seekBaseReset = null;
        _seekBase = null;
        _seekOrigin = null;
      },
    );
  }

  /// The progress bar has taken the position: hold the chrome up for as long
  /// as the drag or the burst lasts.
  void _beginSeekHold() {
    if (_seekChromeHold != null) {
      _chrome.poke();
      return;
    }
    _seekChromeHold = _chrome;
    _chrome.poke(hold: true);
  }

  /// The bar committed [target], or gave it up (null) because the media
  /// changed under the drag. Either way the hold goes back exactly once.
  void _endSeekHold(Duration? target) {
    if (target != null) _rebaseSeekChain(target);
    final held = _seekChromeHold;
    if (held == null) return;
    _seekChromeHold = null;
    held.release();
  }

  /// Stops taps and drags on the bars from reaching the screen-wide gesture
  /// layer beneath them.
  ///
  /// Without this the full-screen double-tap and long-press recognisers stay in
  /// the gesture arena while a button is pressed, so the button's own tap is
  /// delayed behind the double-tap timeout and reads as unresponsive. Deeper
  /// widgets still win normally.
  Widget _absorbGestures(Widget child) => GestureDetector(
    onTap: () {},
    onDoubleTap: () {},
    onLongPress: () {},
    onVerticalDragStart: (_) {},
    onHorizontalDragStart: (_) {},
    child: child,
  );

  /// One of the two discrete seek buttons, on every platform.
  ///
  /// In [_leading] rather than in the actions, so it is pinned beside
  /// play/pause and is never the thing that scrolls or wraps away: it is a
  /// transport control, not a utility.
  Widget _stepButton(
    AppLocalizations l10n,
    int seconds, {
    required bool forward,
    required bool isTv,
  }) {
    return PlayerIconButton(
      icon: _stepIcon(seconds, forward: forward),
      tooltip: _stepLabel(l10n, seconds, forward: forward),
      isTv: isTv,
      onPressed: () {
        _chrome.poke();
        // The centred pill, not the half-screen ripple: only [_doubleTapSeek]
        // asks for a burst, because that one is a tap on a half of the frame
        // and has a side to answer on.
        _seekBy(Duration(seconds: forward ? seconds : -seconds));
      },
    );
  }

  List<Widget> _leading(
    AppLocalizations l10n,
    PlayerSettings settings, {
    required bool isTv,
  }) {
    final int step = _seekStepSeconds(settings);
    return <Widget>[
      // Withheld on a live edge because [_seekBy] returns on `isLive`, so the
      // press would be dead. That is a property of the stream, not the device.
      if (!widget.isLive) _stepButton(l10n, step, forward: false, isTv: isTv),
      PlayerValueSelector<bool>(
        controller: widget.controller,
        // A rebuffer is still playback: the film resumes on its own, so the
        // button keeps offering pause. A play glyph here would say stopped.
        selector: (v) => v.isPlaying || v.isBuffering,
        builder: (context, playing) {
          return PlayerIconButton(
            icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            tooltip: playing ? l10n.pause : l10n.play,
            isTv: isTv,
            iconSize: 40,
            focusNode: _playPause,
            // Only on TV: a keyboard user wants arrows seeking from the
            // start, which they do while the sink holds focus, not a button.
            autofocus: isTv,
            onPressed: () {
              _chrome.poke();
              playing ? widget.controller.pause() : widget.controller.play();
            },
          );
        },
      ),
      if (!widget.isLive) _stepButton(l10n, step, forward: true, isTv: isTv),
      // Between play/pause and Next, the slot player_control_components.dart
      // reserves for it. Absent rather than disabled off touch - see
      // [_lockAvailable].
      if (_lockAvailable)
        PlayerIconButton(
          icon: Icons.lock_outline_rounded,
          tooltip: l10n.lock,
          isTv: isTv,
          onPressed: () {
            // The chip that undoes this rides the chrome's clock, so the
            // press that locks has to be the press that starts it. Otherwise
            // a lock set from bars one tick from expiring leaves a locked
            // screen with no chip on it.
            _chrome.poke();
            widget.locked!.value = true;
          },
        ),
      if (widget.onNextEpisode != null && settings.showEpisodes)
        PlayerIconButton(
          icon: Icons.skip_next_rounded,
          tooltip: l10n.next,
          isTv: isTv,
          onPressed: () {
            _chrome.poke();
            widget.onNextEpisode!.call();
          },
        ),
    ];
  }

  /// The utility group, right-anchored.
  ///
  /// Ordered least-used first, and that ordering is load-bearing. The strip is
  /// right-anchored on touch and the [Wrap] is end-aligned off it, so a
  /// squeeze eats the row from the left: whatever is first in this list is the
  /// first thing a viewer loses on a 360 dp portrait handset. So the torrent
  /// diagnostics and the one-off view settings lead, and audio and subtitles
  /// are last, hard against the right edge where they survive any width.
  List<Widget> _actions(
    AppLocalizations l10n,
    PlayerSettings settings, {
    required bool isTv,
  }) {
    return <Widget>[
      if (widget.torrentStatus != null)
        PlayerIconButton(
          icon: Icons.info_outline,
          tooltip: l10n.torrentStats,
          isTv: isTv,
          highlight: _showTorrentInfo,
          onPressed: () {
            _chrome.poke();
            setState(() => _showTorrentInfo = !_showTorrentInfo);
          },
        ),
      if (_hasPanelTab(PlayerPanelTab.files))
        PlayerIconButton(
          icon: Icons.video_library_outlined,
          tooltip: l10n.torrentFiles,
          isTv: isTv,
          onPressed: () => _open(PlayerPanelTab.files),
        ),
      if (settings.showResize)
        PlayerIconButton(
          icon: Icons.aspect_ratio_rounded,
          tooltip: l10n.resize,
          isTv: isTv,
          onPressed: () {
            _chrome.poke();
            _cycleFit();
          },
        ),
      if (widget.onEnterPip != null && settings.showPip)
        PlayerIconButton(
          icon: Icons.picture_in_picture_alt_rounded,
          tooltip: l10n.pip,
          isTv: isTv,
          onPressed: () {
            _chrome.poke();
            widget.onEnterPip!.call();
          },
        ),
      if (widget.onToggleFullscreen != null)
        PlayerIconButton(
          icon: widget.isFullscreen
              ? Icons.fullscreen_exit_rounded
              : Icons.fullscreen_rounded,
          tooltip: widget.isFullscreen ? l10n.windowed : l10n.fullscreen,
          isTv: isTv,
          onPressed: () {
            _chrome.poke();
            widget.onToggleFullscreen!.call();
          },
        ),
      // The list buttons, each opening the one panel on its own tab. Present
      // exactly when the tab is - see [VlcPlayerControls.panelTabs].
      if (_hasPanelTab(PlayerPanelTab.sources))
        PlayerIconButton(
          icon: Icons.source,
          tooltip: l10n.sources,
          isTv: isTv,
          onPressed: () => _open(PlayerPanelTab.sources),
        ),
      // Behind the same setting as Next: a viewer who hid the episode controls
      // hid all of them.
      if (_hasPanelTab(PlayerPanelTab.episodes) && settings.showEpisodes)
        PlayerIconButton(
          icon: Icons.playlist_play_rounded,
          tooltip: l10n.episodes,
          isTv: isTv,
          onPressed: () => _open(PlayerPanelTab.episodes),
        ),
      // Speed is meaningless on a live edge, so the button is absent there
      // rather than present and inert.
      if (!widget.isLive && settings.showPlaybackSpeed)
        PlayerValueSelector<double>(
          controller: widget.controller,
          selector: (v) => v.playbackSpeed,
          builder: (context, speed) => PlayerIconButton(
            icon: Icons.speed,
            tooltip: '${_formatSpeed(speed)}x',
            isTv: isTv,
            highlight: speed != 1.0,
            onPressed: () => unawaited(_chrome.whileHeld(_pickSpeed)),
          ),
        ),
      // On every platform, not just TV. The vertical rail only carries volume
      // when the viewer's edge-gesture setting says it does, so anyone who set
      // both edges to brightness had no volume path at all, and the 100-200%
      // software boost was reachable on a phone only by dragging past the top
      // of an invisible rail.
      //
      // Not gated on `!widget.isLive` the way speed is: a live edge still has
      // a volume.
      PlayerIconButton(
        icon: Icons.volume_up_rounded,
        tooltip: l10n.volume,
        isTv: isTv,
        onPressed: () => unawaited(_chrome.whileHeld(_pickVolume)),
      ),
      if (_hasPanelTab(PlayerPanelTab.audio))
        PlayerIconButton(
          icon: Icons.audiotrack_rounded,
          tooltip: l10n.audioTracks,
          isTv: isTv,
          onPressed: () => _open(PlayerPanelTab.audio),
        ),
      if (_hasPanelTab(PlayerPanelTab.subtitles))
        PlayerIconButton(
          icon: Icons.subtitles_rounded,
          tooltip: l10n.subtitles,
          isTv: isTv,
          onPressed: () => _open(PlayerPanelTab.subtitles),
        ),
    ];
  }

  /// The fork made fit changeable at runtime (FORK.md section 3), so this is a
  /// straight engine call with no Dart-side state to keep in sync.
  void _cycleFit() {
    const order = <VlcVideoFit>[
      VlcVideoFit.contain,
      VlcVideoFit.cover,
      VlcVideoFit.fill,
    ];
    final next = order[(order.indexOf(widget.fit) + 1) % order.length];
    // Both paths, because which one bites depends on the platform: setFit
    // drives the native view on macOS/Android/iOS, and the callback drives the
    // FittedBox that the Windows/Linux texture path renders through.
    _applyFit(next);
    widget.onFitChanged?.call(next);
    _showToast(_fitLabel(AppLocalizations.of(context)!, next));
  }

  /// Names the band being skipped. SkipType has no localized name of its own -
  /// `.name` is the Dart identifier - so the mapping is spelled out.
  static String _skipLabel(AppLocalizations l10n, SkipType type) =>
      switch (type) {
        SkipType.intro => l10n.skipIntro,
        SkipType.outro => l10n.skipOutro,
        SkipType.recap => l10n.skipRecap,
        SkipType.unknown => l10n.skip,
      };

  String _fitLabel(AppLocalizations l10n, VlcVideoFit fit) => switch (fit) {
    VlcVideoFit.contain => l10n.fit,
    VlcVideoFit.cover => l10n.zoom,
    VlcVideoFit.fill => l10n.stretch,
    VlcVideoFit.none => l10n.original,
  };

  /// Subscribes to the lock, where there is one, and builds the body against
  /// its current answer.
  ///
  /// The subscription is here rather than deeper because the lock changes the
  /// contents of the Stack rather than the appearance of any one child - see
  /// [_buildBody]. Off touch there is no notifier and no builder either.
  @override
  Widget build(BuildContext context) {
    final notifier = _lockAvailable ? widget.locked : null;
    if (notifier == null) return _buildBody(context, locked: false);
    return ValueListenableBuilder<bool>(
      valueListenable: notifier,
      builder: (context, locked, _) => _buildBody(context, locked: locked),
    );
  }

  /// Suppression in one place, not eight.
  ///
  /// Everything the lock has to swallow - the chrome toggle, the double-tap
  /// seek, the horizontal scrub, the vertical rail and the long-press speed
  /// boost - is registered on the single screen-wide [GestureDetector] below,
  /// so locking rebuilds that one widget with a bare `onTap` and every gesture
  /// is gone at once.
  ///
  /// Three things are withheld rather than guarded, because each is a live
  /// target of its own outside that detector: [_bars], the centre play/pause
  /// and the skip chip.
  ///
  /// Everything else stays: the spinner, the torrent panel, the rail and the
  /// toast are all `IgnorePointer` and read-only.
  Widget _buildBody(BuildContext context, {required bool locked}) {
    final l10n = AppLocalizations.of(context)!;
    final isTv =
        playerFormFactorOf(ref.watch(deviceProfileProvider).asData?.value) ==
        PlayerFormFactor.tv;
    final isTouch = !isTv && (Platform.isAndroid || Platform.isIOS);
    final settings =
        ref.watch(playerSettingsProvider).asData?.value ??
        const PlayerSettings();
    final visible = _chrome.value;

    Widget body = Focus(
      focusNode: _sink,
      onKeyEvent: _handleKey,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Bare tap on the video toggles the chrome. Sits below the bars,
          // which absorb their own gestures so buttons are never delayed
          // behind the double-tap timeout.
          //
          // Locked, this is a different widget rather than the same one with
          // nine guarded callbacks, so the tenth gesture somebody adds is
          // inert for free. The surviving tap is `poke`, not `toggle`: while
          // locked, a touch is a request to see the unlock chip and never a
          // request to hide it.
          if (locked)
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _chrome.poke,
            )
          else
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _chrome.toggle,
              // Desktop convention; on touch the same gesture seeks instead,
              // which is why the two are mutually exclusive.
              onDoubleTap: widget.onToggleFullscreen,
              onDoubleTapDown: (!_isDesktop && settings.doubleTapEnabled)
                  ? (d) => _doubleTapSeek(d.localPosition.dx)
                  : null,
              onVerticalDragStart: (d) => unawaited(_railDragStart(d)),
              onVerticalDragUpdate: _railDragUpdate,
              onVerticalDragEnd: (_) => _railDragEnd(),
              onVerticalDragCancel: _railDragEnd,
              onHorizontalDragStart: (d) => _onHorizontalDragStart(d, settings),
              onHorizontalDragUpdate: (d) =>
                  _onHorizontalDragUpdate(d, settings),
              onHorizontalDragEnd: _onHorizontalDragEnd,
              onHorizontalDragCancel: () {
                _horizontalDragStartX = null;
                _horizontalDragStartPosition = null;
                _horizontalDragTarget = null;
              },
              onLongPressStart: (_) => _startSpeedBoost(),
              onLongPressEnd: (_) => _endSpeedBoost(),
              onLongPressCancel: _endSpeedBoost,
            ),
          // Reads through even when the chrome is hidden. Off Android, libVLC
          // keeps saying `playing` through a rebuffer; the controller's
          // position clock is what knows the frame has frozen.
          RepaintBoundary(
            child: PlayerValueSelector<bool>(
              controller: widget.controller,
              selector: (v) => v.isStalled || v.isBuffering,
              builder: (context, buffering) => buffering
                  ? const PlayerBufferingIndicator()
                  : const SizedBox.shrink(),
            ),
          ),
          // The touch build's primary control, above the screen-wide detector
          // in the Stack so hit testing reaches it first, and outside [_bars]
          // because it holds no node - so `_chromeRoot.hasFocus` still means
          // exactly "a control is focused".
          //
          // Center is outside the fade and the fade is outside everything
          // else: `Positioned.fill(AnimatedOpacity(Center(...)))` would size
          // the opacity layer to the whole viewport, which over a platform
          // view is the window-sized surface this file's header forbids.
          //
          // The IgnorePointer is not optional. Nothing else withdraws the
          // glyph when the bars go down, and a 72 px invisible circle in the
          // dead centre would eat the tap-to-reveal that is the only way back.
          //
          // Withheld outright while locked rather than left to that
          // IgnorePointer, which only tracks the chrome: a lock reveals the
          // chrome to show its chip, so the glyph would be up and hit-testable
          // dead centre.
          if (_showCenterGlyph && !locked)
            Center(
              child: _fading(
                IgnorePointer(
                  ignoring: !visible,
                  child: RepaintBoundary(
                    child: PlayerValueSelector<(bool, bool)>(
                      controller: widget.controller,
                      // A rebuffer is still playback, exactly as _leading
                      // reads it, so the glyph keeps offering pause; and while
                      // the spinner is up the glyph collapses, so the two
                      // never draw a disc around each other.
                      selector: (v) => (
                        v.isPlaying || v.isBuffering,
                        v.isStalled || v.isBuffering,
                      ),
                      builder: (context, state) {
                        final (playing, busy) = state;
                        if (busy) return const SizedBox.shrink();
                        return PlayerCenterPlayButton(
                          playing: playing,
                          label: playing ? l10n.pause : l10n.play,
                          onPressed: () {
                            _chrome.poke();
                            playing
                                ? widget.controller.pause()
                                : widget.controller.play();
                          },
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            top: MediaQuery.viewPaddingOf(context).top + 72,
            right: isTv ? 48 : 16,
            // Refreshed by the screen's 3 s poll, so the panel repaints on a
            // schedule and must do so alone.
            child: RepaintBoundary(
              child: IgnorePointer(
                child: _showTorrentInfo && widget.torrentStatus != null
                    ? TorrentInfoWidget(status: widget.torrentStatus)
                    : const SizedBox.shrink(),
              ),
            ),
          ),
          // Both read through hidden chrome: resize, seek and volume are
          // reachable by remote while the bars are down, and a silent change
          // confuses. Each is mounted once and driven by its notifier.
          TransientOverlay<PlayerRail>(
            value: _rail,
            builder: (_, rail) => rail,
          ),
          TransientOverlay<String>(
            value: _toast,
            // Nudged up off the centre play/pause where there is one: the
            // toast is painted above the glyph, so a swipe readout or the 2x
            // label would otherwise land dead on the disc.
            builder: (_, message) => PlayerToast(
              message,
              alignment: _showCenterGlyph
                  ? const Alignment(0, -0.34)
                  : Alignment.center,
            ),
          ),
          // Only a double-tap writes here. Beside the toast rather than in
          // place of it, so a swipe pill and a tap burst can each be the last
          // thing that happened without either clearing the other's timer.
          TransientOverlay<SeekBurst>(
            value: _burst,
            builder: (_, burst) => PlayerSeekBurst(
              forward: burst.forward,
              seconds: burst.seconds,
              revision: burst.revision,
            ),
          ),
          // The whole focusable chrome, or - locked - the one control that
          // undoes the lock, in the same slot. Never both: a locked player
          // with a seek bar on it is not locked.
          if (locked)
            _unlockChip(l10n)
          else
            _bars(context, l10n, settings, isTv: isTv, isTouch: isTouch),
          // Outside the chrome on purpose: an intro can start while the bars
          // are hidden, and putting the one time-limited control behind a tap
          // would defeat it. Which is also why it has to be withdrawn by hand
          // when the screen raises a prompt into the same corner, and why
          // `locked` has to be named here - otherwise a locked screen keeps a
          // live, D-pad-reachable Skip button.
          RepaintBoundary(
            child: Align(
              alignment: Alignment.bottomRight,
              child:
                  widget.skipSegments.isEmpty || widget.promptVisible || locked
                  ? const SizedBox.shrink()
                  : _skipButton(isTv: isTv),
            ),
          ),
        ],
      ),
    );

    // Hover is desktop only: touch has none and a remote has no pointer.
    if (_isDesktop) {
      body = MouseRegion(
        // Derived from the same value as the bars so it cannot desync; the
        // route's teardown puts the platform cursor back.
        cursor: visible ? MouseCursor.defer : SystemMouseCursors.none,
        onHover: _onHover,
        child: body,
      );
    }

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _chrome.keepAlive(),
      child: body,
    );
  }

  /// Motion only - the position is compared - so an overlay animating under a
  /// stationary cursor does not re-arm the clock forever.
  void _onHover(PointerHoverEvent event) {
    if (event.position == _hoverAt) return;
    _hoverAt = event.position;
    _chrome.poke();
  }

  Widget _bars(
    BuildContext context,
    AppLocalizations l10n,
    PlayerSettings settings, {
    required bool isTv,
    required bool isTouch,
  }) {
    final visible = _chrome.value;
    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      // ExcludeFocus, on a node this State can ask about.
      child: Focus(
        focusNode: _chromeRoot,
        descendantsAreFocusable: visible,
        includeSemantics: false,
        child: IgnorePointer(
          ignoring: !visible,
          // One Column, bottom-anchored, and one fade per bar rather than one
          // around the Column. The bars sit at opposite screen edges, so a
          // single opacity layer around both is window-sized; two are each
          // bar-sized, and the spacer between them is in neither.
          child: Column(
            children: [
              _fading(
                _absorbGestures(
                  _holdWhileHovered(
                    PlayerTopBar(
                      title: widget.title,
                      subtitle: widget.subtitle,
                      onBack: widget.onBack,
                      isTv: isTv,
                    ),
                  ),
                ),
              ),
              const Expanded(child: SizedBox.expand()),
              _fading(
                _absorbGestures(
                  _holdWhileHovered(
                    PlayerBottomBar(
                      isTv: isTv,
                      isTouch: isTouch,
                      // Its own boundary: the scrubber repaints on every
                      // position tick, which would otherwise repaint the whole
                      // bottom bar, scrim and every icon button.
                      progressBar: RepaintBoundary(
                        child: VlcProgressBar(
                          controller: widget.controller,
                          isTv: isTv,
                          isLive: widget.isLive,
                          skipSegments: widget.skipSegments,
                          // Held for the drag or the D-pad burst, then
                          // released: the seek bar commits both as one end,
                          // and reports one even when it cannot commit, so the
                          // hold can never be stranded.
                          onSeekStart: _beginSeekHold,
                          onSeekEnd: _endSeekHold,
                        ),
                      ),
                      leading: _leading(l10n, settings, isTv: isTv),
                      actions: _actions(l10n, settings, isTv: isTv),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A bar under the mouse is being read or about to be clicked and must not
  /// fade out from under the cursor.
  Widget _holdWhileHovered(Widget bar) =>
      !_isDesktop ? bar : _HoverChromeHold(chrome: _chrome, child: bar);

  /// No RepaintBoundary of its own: RenderAnimatedOpacity is one for as long
  /// as alpha > 0, which is exactly when the bar is on screen, and at alpha 0
  /// it paints nothing to protect. A second boundary here would be the same
  /// bounds twice and one more surface over the platform view.
  Widget _fading(Widget bar) => AnimatedOpacity(
    opacity: _chrome.value ? 1 : 0,
    duration: _fade,
    child: bar,
  );

  /// The one control a locked player has, and the only way back into the
  /// player short of leaving it.
  ///
  /// Rides the chrome's own clock through [_fading]: a touch anywhere pokes
  /// the chrome, the chip appears with it, and both go away together. No
  /// second timer and no second opacity controller to keep in step.
  ///
  /// The [IgnorePointer] is load-bearing. `AnimatedOpacity` at zero paints
  /// nothing but still hit-tests, so without it an invisible chip would sit at
  /// the bottom of a locked screen and the first accidental contact would undo
  /// the lock.
  ///
  /// Bottom-centre because a thumb reaches the middle of the bottom edge on
  /// any handset, clear of the dead centre where a swipe-seek would start.
  Widget _unlockChip(AppLocalizations l10n) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 32),
          child: _fading(
            IgnorePointer(
              ignoring: !_chrome.value,
              child: _chipPill(
                PlayerActionButton(
                  // Says what state the player is in; the label says what the
                  // press does.
                  icon: Icons.lock_rounded,
                  label: l10n.unlock,
                  onTap: () {
                    _chrome.poke();
                    // Writing the shared flag is the whole of the unlock: the
                    // screen owns everything that follows from it, the
                    // two-press Back escape above all, by listening to this
                    // notifier rather than by being called.
                    widget.locked!.value = false;
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The painted pill a chip wears so it is readable over a bright frame.
  ///
  /// [PlayerActionButton]'s own background is fully transparent until it is
  /// focused or hovered, which on a bright scene is white glyphs on white with
  /// no edge at all, and on a television there is no hover to rescue it.
  ///
  /// A paint, not a layer: `DecoratedBox` draws into the layer it is already
  /// in, unlike the backdrop filters this file's header forbids.
  static Widget _chipPill(Widget child) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xB3000000),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: HotstarPlayerStyle.divider),
    ),
    child: child,
  );

  /// Shown only while the position is genuinely inside a segment, so it appears
  /// and disappears on its own and never needs dismissing.
  ///
  /// On an outro with an episode behind it the chip says Next and hands over
  /// to [VlcPlayerControls.onSkipOutro], but it still seeks first.
  /// `PlaybackTracker` judges a session complete from the last sample taken
  /// while playing, and an outro band routinely starts before
  /// `kCompletedFraction` (0.90), so advancing from inside it would report a
  /// `scrobbleStop` to Trakt and Simkl where the viewer earned a play. The
  /// target is the later of the band's end and a point past the completion
  /// line. When that seek cannot land the chip is withheld; see
  /// [_advanceWithheld].
  Widget _skipButton({required bool isTv}) {
    return PlayerValueSelector<(SkipSegment?, bool)>(
      controller: widget.controller,
      // [_advanceWithheld] is answered in the selector rather than read off
      // the controller in the builder because this widget only rebuilds when
      // the selector's own output changes, and the segment alone does not
      // change when the engine starts reporting the source seekable. Read in
      // the builder, the withheld chip would never come back.
      selector: (v) {
        final SkipSegment? segment = segmentAt(widget.skipSegments, v.position);
        return (segment, segment != null && _advanceWithheld(segment, v));
      },
      builder: (context, state) {
        final (SkipSegment? segment, bool withheld) = state;
        if (segment == null || withheld) return const SizedBox.shrink();
        final bool advances =
            segment.type == SkipType.outro && widget.onSkipOutro != null;
        return Padding(
          padding: EdgeInsets.only(
            right: isTv ? 48 : 24,
            bottom: _chrome.value ? 132 : 48,
          ),
          // The same pill the unlock chip wears, through the one helper.
          child: _chipPill(
            PlayerActionButton(
              label: advances
                  ? AppLocalizations.of(context)!.next
                  : _skipLabel(AppLocalizations.of(context)!, segment.type),
              icon: advances
                  ? Icons.skip_next_rounded
                  : Icons.fast_forward_rounded,
              isTv: isTv,
              focusNode: _skipFocus,
              onTap: () {
                _chrome.poke();
                final target = advances
                    ? _outroAdvancePoint(segment)
                    : Duration(milliseconds: (segment.endTime * 1000).round());
                widget.controller.seekTo(target);
                _rebaseSeekChain(target);
                if (advances) widget.onSkipOutro!.call();
              },
            ),
          ),
        );
      },
    );
  }

  /// Whether the advancing form of the skip chip has to stay off screen.
  ///
  /// True for the Next chip, and only for it, on a source libVLC reports as
  /// unseekable. The seek to [_outroAdvancePoint] is what makes the hand-over
  /// safe and it cannot land there, so advancing from inside the outro would
  /// report a `scrobbleStop` at roughly 0.88 to Trakt and Simkl and never
  /// write `episodeWatchRepository.setWatched`. The chip comes back the moment
  /// the engine reports the source seekable - routine on a torrent still
  /// filling its pieces in.
  ///
  /// There is no "already past the line" case to let through: the chip only
  /// exists while [segmentAt] answers, which is strictly inside the band, and
  /// [_outroAdvancePoint] is at or past that band's end.
  ///
  /// Deliberately narrow. An intro, a recap, or an outro with no episode
  /// behind it is a pure seek, and on an unseekable source it stays a dead
  /// press: that costs the viewer a press, not a watch.
  bool _advanceWithheld(SkipSegment segment, VlcPlayerValue value) =>
      segment.type == SkipType.outro &&
      widget.onSkipOutro != null &&
      !value.isSeekable;

  /// Where "I am done with this episode" has to land before anything advances.
  ///
  /// The later of the outro band's end and [_outroAdvanceFraction] of the
  /// duration. The margin over `kCompletedFraction` is deliberate: the engine
  /// lands a seek approximately, and a sample a hair under the line reads as
  /// unwatched. With no duration reported yet the band's end is all there is.
  Duration _outroAdvancePoint(SkipSegment segment) {
    final Duration bandEnd = Duration(
      milliseconds: (segment.endTime * 1000).round(),
    );
    final Duration duration = widget.controller.value.duration;
    if (duration <= Duration.zero) return bandEnd;
    final Duration line = Duration(
      milliseconds: (duration.inMilliseconds * _outroAdvanceFraction).round(),
    );
    return line > bandEnd ? line : bandEnd;
  }
}

/// Holds the chrome up while the mouse rests on [child], and gives that hold
/// back exactly once — on exit, or on teardown if the exit never comes.
///
/// A [State] of its own rather than a [MouseRegion] inline in the controls,
/// because the release has to happen when this subtree goes, not when the
/// controls do. Flutter deliberately does not deliver [MouseRegion.onExit]
/// when the region is unmounted with the pointer still inside it
/// (widgets/basic.dart), and the documented mitigation is to release from
/// [dispose]. The hold is counted, so an enter with no matching exit pins the
/// bars up for the rest of the session on a chrome that usually outlives these
/// controls. Children are unmounted before their parents, so this runs while
/// the controls' private chrome is still alive.
class _HoverChromeHold extends StatefulWidget {
  const _HoverChromeHold({required this.chrome, required this.child});

  final ChromeVisibilityController chrome;
  final Widget child;

  @override
  State<_HoverChromeHold> createState() => _HoverChromeHoldState();
}

class _HoverChromeHoldState extends State<_HoverChromeHold> {
  /// The controller this is holding up, if it is. Which one, not whether: the
  /// screen can swap the chrome mid-hover, and the hold has to go back to the
  /// controller that took it rather than tripping `assert(_holds > 0)` on a
  /// controller that never gave one.
  ChromeVisibilityController? _held;

  /// Idempotent: a second pointer entering the same bar pokes rather than
  /// taking a hold that the first pointer's exit would then strand.
  void _begin() {
    if (_held != null) {
      widget.chrome.poke();
      return;
    }
    _held = widget.chrome;
    widget.chrome.poke(hold: true);
  }

  void _release() {
    final held = _held;
    if (held == null) return;
    _held = null;
    held.release();
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  /// Translucent, so this adds hover and not a hit target.
  @override
  Widget build(BuildContext context) => MouseRegion(
    hitTestBehavior: HitTestBehavior.translucent,
    onEnter: (_) => _begin(),
    onExit: (_) => _release(),
    child: widget.child,
  );
}
