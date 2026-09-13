import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';

/// Whether the player chrome is on screen, and the one clock that takes it
/// away.
///
/// The old overlay restarted its hide timer from sixteen call sites and the
/// first VLC chrome from six, and both leaked the same two ways: a path that
/// forgot let the bars vanish mid-interaction, and a path that cancelled the
/// timer without re-arming - a D-pad seek - left them up for good. Here the
/// timer has no public surface. Callers say what happened - a [poke], a
/// [toggle], a hold for as long as a sheet or a drag or a resting mouse lasts -
/// and the clock is a consequence.
///
/// A [ValueNotifier] rather than widget state so gesture callbacks, key
/// handlers, sheet lifetimes and hover can all drive it without any of them
/// owning a setState; the chrome listens once.
class ChromeVisibilityController extends ValueNotifier<bool> {
  /// Born visible and armed. Nothing hides until [isPlaying] reports true, so
  /// the bars stay up through resolution and buffering.
  ChromeVisibilityController({
    required bool Function() isPlaying,
    this.hideAfter = const Duration(seconds: 3),
  }) : _isPlaying = isPlaying,
       super(true) {
    _restart();
  }

  /// The default matches the old overlay (skystream_player_controls.dart:689).
  final Duration hideAfter;
  final bool Function() _isPlaying;

  Timer? _timer;
  int _holds = 0;
  bool _disposed = false;

  /// Whether an assistive technology is driving navigation - TalkBack,
  /// VoiceOver, Switch Access.
  ///
  /// Exactly the bit `MediaQuery.accessibleNavigationOf` reports:
  /// `MediaQueryData.fromView` copies it straight off
  /// [PlatformDispatcher.accessibilityFeatures]. Read off the binding rather
  /// than a context because this clock lives outside the widget tree, and read
  /// live on every decision rather than cached at construction, because a
  /// viewer can turn a screen reader on in the middle of a film.
  static bool get _accessibleNavigation => SemanticsBinding
      .instance
      .platformDispatcher
      .accessibilityFeatures
      .accessibleNavigation;

  /// True while something owns the screen - a sheet, a drag, a mouse resting
  /// on a bar - and the chrome must not go out from under it.
  bool get isHeld => _holds > 0;

  /// Something happened that the viewer should see the chrome for. Reveals it
  /// if hidden and restarts the clock either way.
  ///
  /// With [hold] the clock stops instead, until the matching [release]. Holds
  /// nest, so a sheet opened from a hovered bar comes out right whichever
  /// ends first.
  void poke({bool hold = false}) {
    if (hold) _holds++;
    value = true;
    _restart();
  }

  /// Ends one hold. The clock re-arms only when the last one goes.
  void release() {
    assert(_holds > 0, 'release without a matching hold');
    if (_holds > 0) _holds--;
    _restart();
  }

  /// Keeps visible chrome alive without revealing hidden chrome. For raw
  /// pointer-down: a tap that dismisses the bars also produces one, and if
  /// that re-showed them the bars could never be dismissed at all.
  void keepAlive() {
    if (value) _restart();
  }

  /// The bare tap on the video. Hiding here is the viewer's explicit choice,
  /// so it goes through even while paused; a hold still wins, because what is
  /// being held is not what was tapped.
  void toggle() {
    if (!value) {
      poke();
    } else if (isHeld) {
      _restart();
    } else {
      _hide();
    }
  }

  /// Holds for the life of [action] - a sheet, a dialog - then re-arms.
  Future<T> whileHeld<T>(Future<T> Function() action) async {
    poke(hold: true);
    try {
      return await action();
    } finally {
      release();
    }
  }

  void _restart() {
    _timer?.cancel();
    _timer = null;
    if (_disposed || !value || isHeld) return;
    // A screen reader explores by swiping or flicking between elements, which
    // dispatches no pointer event to Flutter, so nothing in that exploration
    // pokes this clock. Left armed it takes the bars away mid-exploration -
    // and not just visually: both bars hide behind an opacity-0
    // AnimatedOpacity, and RenderAnimatedOpacityMixin drops a fully
    // transparent subtree from the semantics tree, so all thirteen bottom-bar
    // controls leave the accessibility tree and focus resets. Three seconds is
    // two to four element stops; Subtitles and Audio are unreachable. So while
    // an assistive technology is driving, the chrome stays - which is what
    // Netflix and YouTube do too.
    if (_accessibleNavigation) return;
    _timer = Timer(hideAfter, _expire);
  }

  void _expire() {
    // Paused means the viewer is looking at something - a still frame, the
    // seek bar, the title. Hiding out from under them is the wrong call, so
    // wait and re-check rather than hiding on a schedule. Same for a screen
    // reader switched on after this timer was armed: [_restart] declines to
    // re-arm, so the bars simply stay.
    if (!_isPlaying() || _accessibleNavigation) {
      _restart();
      return;
    }
    _hide();
  }

  void _hide() {
    _timer?.cancel();
    _timer = null;
    value = false;
  }

  /// A sheet can outlive the player and release its hold afterwards; that
  /// must not start a timer into a dead notifier.
  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
