/// Compile-time switches for hunting the macOS black flicker on a real machine.
///
/// All three are `--dart-define` flags, so a build carries none of them unless
/// asked, and none of them can be reached from settings. They exist because
/// every explanation of the flicker so far has come from reading code, and two
/// of those explanations were wrong; these produce evidence instead.
///
///   flutter run --dart-define=PLAYER_PLATFORM_VIEW=true
///       Renders video through the platform view - AppKitView / UiKitView /
///       AndroidView - instead of a Flutter texture. The texture became the
///       default on every platform on 2026-09-06 after the macOS view was
///       shown to drop the video for a frame on every control interaction.
///       This is the escape hatch for an A/B if a texture path ever looks
///       wrong on a device.
///
///   flutter run -d macos --dart-define=PLAYER_DEBUG_COLORS=true
///       Paints the surface BELOW the video magenta and the player widget's
///       own backdrop lime. A flash that shows either colour is Flutter letting
///       something underneath through - an overlay surface presented before it
///       was rastered. A flash that stays BLACK is the VLC view itself going
///       blank, which is a different bug in a different layer.
///
///   flutter run -d macos --dart-define=PLAYER_REPAINT_RAINBOW=true
///       Flutter's repaint rainbow: every repainted region cycles colour. Shows
///       exactly how much of the overlay repaints when the pointer moves over
///       a control.
/// A second family lives below in [PlayerDiagnostics]: environment variables
/// rather than `--dart-define`, read at run time. The distinction is the whole
/// point of them. A `--dart-define` is baked in, so asking a tester to try the
/// switch both ways means sending two builds; an environment variable means
/// sending one and asking them to run it twice. That is the difference between
/// a support round trip that settles a question and one that does not, and it
/// matters most on the platform nobody here owns a machine for.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vlc_player/vlc_player.dart';

const bool kPlayerDebugPlatformView = bool.fromEnvironment(
  'PLAYER_PLATFORM_VIEW',
);
const bool kPlayerDebugColors = bool.fromEnvironment('PLAYER_DEBUG_COLORS');
const bool kPlayerRepaintRainbow = bool.fromEnvironment(
  'PLAYER_REPAINT_RAINBOW',
);

/// Which Darwin renderer this build should use.
VlcDarwinRenderer get playerDarwinRenderer => kPlayerDebugPlatformView
    ? VlcDarwinRenderer.platformView
    : VlcPlayerConfig.defaultDarwinRenderer;

/// Which Android renderer this build should use. Same flag, same meaning.
VlcAndroidRenderer get playerAndroidRenderer => kPlayerDebugPlatformView
    ? VlcAndroidRenderer.platformView
    : VlcPlayerConfig.defaultAndroidRenderer;

/// The colour under the whole player. Black in a normal build.
Color get playerScaffoldColor =>
    kPlayerDebugColors ? const Color(0xFFFF00FF) : Colors.black;

/// The colour the player widget paints behind the video. Black normally.
Color get playerBackdropColor =>
    kPlayerDebugColors ? const Color(0xFF00FF00) : Colors.black;

/// Run-time diagnostic switches, read from the process environment.
///
/// Every switch here is off unless the variable is set, so a normal launch
/// behaves exactly as it did. They exist for the case the flags above cannot
/// serve: a crash on a platform nobody on the team has a machine for, where
/// the only instrument available is a person who will run one command and
/// paste what it printed.
///
///   SKYSTREAM_VLC_VERBOSE=1
///       Raises libVLC from `--quiet` to `--verbose=2`. libVLC writes its own
///       log to stderr - no log callback is installed anywhere in the plugin -
///       so this turns a silent run into a transcript of demux, decoder and
///       video-output negotiation. That transcript is what says whether a
///       crash happened before or after the first picture was decoded, which
///       is the question no amount of reading settles.
///
///   SKYSTREAM_NO_VIDEO=1
///       Keeps the whole engine - creation, media, audio, controls, position -
///       and stops only the video surface being painted. The player widget
///       stays mounted, because it is what attaches the native player on the
///       texture platforms; it is put offstage instead, so the `Texture` layer
///       is never composited and the embedder never asks the plugin for a
///       pixel buffer.
///
///       It is a bisector, not a feature. Playback that survives with this set
///       and dies without it puts the fault in the texture/compositor path and
///       clears the decoder; a crash with it set clears the texture path and
///       sends the search back to demux or decode. Nothing else available to
///       a remote tester separates those two halves in one run.
abstract final class PlayerDiagnostics {
  /// The environment the switches are read from.
  ///
  /// A field rather than a direct [Platform.environment] read so a test can
  /// state the environment it is describing. Reset it in a tear-down.
  @visibleForTesting
  static Map<String, String> environment = Platform.environment;

  /// Generous on purpose: the person setting this is following instructions
  /// pasted into a chat window, and `true`, `yes` and `1` are all things they
  /// will reasonably type. Anything else - including unset, empty and `0` -
  /// is off, so no accidental value can turn a switch on.
  static bool _isOn(String name) =>
      switch (environment[name]?.trim().toLowerCase()) {
        '1' || 'true' || 'yes' || 'on' => true,
        _ => false,
      };

  /// Whether libVLC should log at `--verbose=2` instead of `--quiet`.
  static bool get verboseVlcLog => _isOn('SKYSTREAM_VLC_VERBOSE');

  /// Whether the video surface should be kept off the screen.
  static bool get suppressVideoSurface => _isOn('SKYSTREAM_NO_VIDEO');
}
