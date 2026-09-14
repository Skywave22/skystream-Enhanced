/// Compile-time switches for diagnosing player rendering on a real machine.
///
/// All three are `--dart-define` flags, so a build carries none of them unless
/// asked, and none of them can be reached from settings.
///
///   flutter run --dart-define=PLAYER_PLATFORM_VIEW=true
///       Renders video through the platform view - AppKitView / UiKitView /
///       AndroidView - instead of a Flutter texture. The escape hatch for an
///       A/B if a texture path ever looks wrong on a device.
///
///   flutter run -d macos --dart-define=PLAYER_DEBUG_COLORS=true
///       Paints the surface below the video magenta and the player widget's
///       own backdrop lime. A flash of either colour is Flutter letting
///       something underneath through; a flash that stays black is the VLC
///       view itself going blank, a different bug in a different layer.
///
///   flutter run -d macos --dart-define=PLAYER_REPAINT_RAINBOW=true
///       Flutter's repaint rainbow: every repainted region cycles colour, so
///       it shows how much of the overlay repaints on a pointer move.
///
/// [PlayerDiagnostics] below holds a second family, read from environment
/// variables at run time so one build can be run both ways.
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

VlcDarwinRenderer get playerDarwinRenderer => kPlayerDebugPlatformView
    ? VlcDarwinRenderer.platformView
    : VlcPlayerConfig.defaultDarwinRenderer;

VlcAndroidRenderer get playerAndroidRenderer => kPlayerDebugPlatformView
    ? VlcAndroidRenderer.platformView
    : VlcPlayerConfig.defaultAndroidRenderer;

Color get playerScaffoldColor =>
    kPlayerDebugColors ? const Color(0xFFFF00FF) : Colors.black;

Color get playerBackdropColor =>
    kPlayerDebugColors ? const Color(0xFF00FF00) : Colors.black;

/// Run-time diagnostic switches, read from the process environment.
///
/// Every switch here is off unless its variable is set, so a normal launch
/// behaves exactly as it did.
///
///   SKYSTREAM_VLC_VERBOSE=1
///       Raises libVLC from `--quiet` to `--verbose=2`. libVLC writes its own
///       log to stderr - no log callback is installed anywhere in the plugin -
///       so this turns a silent run into a transcript of demux, decoder and
///       video-output negotiation.
///
///   SKYSTREAM_NO_VIDEO=1
///       Keeps the whole engine - creation, media, audio, controls, position -
///       and stops only the video surface being painted. The player widget
///       stays mounted, because it is what attaches the native player on the
///       texture platforms; it is put offstage instead, so the `Texture` layer
///       is never composited and the embedder never asks the plugin for a
///       pixel buffer.
///
///       A bisector, not a feature: playback that survives with this set and
///       dies without it puts the fault in the texture/compositor path rather
///       than in demux or decode.
abstract final class PlayerDiagnostics {
  /// The environment the switches are read from.
  ///
  /// A field rather than a direct [Platform.environment] read so a test can
  /// replace it. Reset it in a tear-down.
  @visibleForTesting
  static Map<String, String> environment = Platform.environment;

  /// Generous on purpose: `1`, `true`, `yes` and `on` all count. Anything
  /// else - including unset, empty and `0` - is off, so no accidental value
  /// can turn a switch on.
  static bool _isOn(String name) =>
      switch (environment[name]?.trim().toLowerCase()) {
        '1' || 'true' || 'yes' || 'on' => true,
        _ => false,
      };

  /// Whether libVLC should log at `--verbose=2` instead of `--quiet`.
  static bool get verboseVlcLog => _isOn('SKYSTREAM_VLC_VERBOSE');

  static bool get suppressVideoSurface => _isOn('SKYSTREAM_NO_VIDEO');
}
