/// Typed configuration that compiles to libVLC command-line options.
///
/// Build a [VlcPlayerConfig] and pass [VlcPlayerConfig.toOptions] as the
/// controller's raw `options`. Raw options stay supported through
/// [VlcPlayerConfig.extraOptions], which are appended last.
library;

import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

/// Hardware-accelerated decoding preference, mapped to `--avcodec-hw`.
enum VlcHardwareAcceleration {
  /// Let VLC pick a hardware decoder if one is available (`any`).
  automatic,

  /// Force software decoding (`none`).
  ///
  /// A fallback after a hardware decoder has failed: some low-end decoders
  /// fail only on specific codec profiles.
  disabled,

  /// Leave the option unset and use whatever the platform build defaults to.
  platformDefault,
}

/// How aggressively the decoder may skip work when it falls behind.
///
/// Maps to `--avcodec-skiploopfilter` / `--avcodec-skip-frame`. Raising this
/// trades picture quality for the ability to keep up on a weak CPU, which is
/// the usual trade on low-end set-top boxes.
enum VlcDecodeThrift {
  /// Decode everything. Best quality.
  none,

  /// Skip the loop filter on non-reference frames. Small quality cost.
  light,

  /// Skip the loop filter on non-keyframes and drop non-reference frames.
  aggressive,
}

/// Which rendition an adaptive (HLS/DASH) stream should start on.
enum VlcAdaptiveLogic {
  /// Estimate available bandwidth and adapt (VLC default).
  rate,

  /// Always pick the lowest rendition. Fastest start, lowest quality.
  lowest,

  /// Always pick the highest rendition.
  highest;

  String get _value => switch (this) {
    VlcAdaptiveLogic.rate => 'rate',
    VlcAdaptiveLogic.lowest => 'lowest',
    VlcAdaptiveLogic.highest => 'highest',
  };
}

/// What happens to playback when the host application leaves the foreground.
///
/// Not a libVLC option: libVLC has no notion of an application lifecycle, so
/// the policy is held here and every embedder inherits the same answer.
enum VlcBackgroundPolicy {
  /// Pause on the way out, and resume on the way back.
  ///
  /// The resume only happens when this policy is what paused it, so a player
  /// the viewer paused deliberately stays paused.
  pause,

  /// Leave the player decoding.
  ///
  /// Spelled this way because `continue` is a reserved word.
  keepPlaying,
}

/// How the video surface reaches the screen on macOS and iOS.
enum VlcDarwinRenderer {
  /// A native platform view (`AppKitView` / `UiKitView`) holding VLC's own
  /// video view.
  ///
  /// Any Flutter widget drawn above the video makes the embedder composite
  /// Flutter content over a native view, and that composite can drop the video
  /// for a frame.
  platformView,

  /// A Flutter `Texture` fed from a CVPixelBuffer pool.
  ///
  /// The video sits inside the Flutter layer tree, so controls painted over it
  /// are ordinary Flutter painting. One renderer serves macOS and iOS.
  texture,
}

/// How the video surface reaches the screen on Android.
enum VlcAndroidRenderer {
  /// A native platform view (`AndroidView`) holding a `VLCVideoLayout`.
  ///
  /// Does not flicker, but costs two full-frame compositions per frame
  /// (MediaCodec into the layout's TextureView, then the view into Flutter), a
  /// frame of latency, and a focus node the widget excludes from traversal.
  platformView,

  /// A Flutter `Texture` fed straight from the decoder.
  ///
  /// libVLC draws into a surface the engine owns, so the video is composited
  /// once and fit and clipping are ordinary widget layout. libVLC blends
  /// subtitles into the picture because there is no second surface for them.
  texture,
}

/// Network and HTTP behaviour.
@immutable
class VlcNetworkConfig {
  const VlcNetworkConfig({
    this.networkCaching,
    this.liveCaching,
    this.fileCaching,
    this.userAgent,
    this.referer,
    this.adaptiveLogic,
    this.adaptiveMaxHeight,
    this.prefetchBufferKiB,
  });

  /// Buffer held for network streams, in milliseconds (`--network-caching`).
  ///
  /// VLC's default is 1000. Raise it on unreliable connections at the cost of
  /// start-up latency; lower it for snappier seeks on a good connection.
  final int? networkCaching;

  /// Buffer held for live streams, in milliseconds (`--live-caching`).
  final int? liveCaching;

  /// Buffer held for local files, in milliseconds (`--file-caching`).
  final int? fileCaching;

  /// Default `User-Agent` for HTTP media (`--http-user-agent`).
  ///
  /// Applied instance-wide. A `User-Agent` on `VlcMediaSource.httpHeaders`
  /// becomes a per-media option and overrides this through VLC's variable
  /// inheritance. Many CDNs reject the stock libVLC agent.
  final String? userAgent;

  /// Default `Referer` for HTTP media (`--http-referrer`).
  final String? referer;

  /// Rendition-selection strategy for HLS/DASH (`--adaptive-logic`).
  final VlcAdaptiveLogic? adaptiveLogic;

  /// Cap on adaptive rendition height, e.g. 1080 (`--adaptive-maxheight`).
  ///
  /// Pinning it below the panel resolution keeps a weak device from selecting
  /// a rendition it cannot decode.
  final int? adaptiveMaxHeight;

  /// How much of a network stream to hold in memory ahead of and behind the
  /// read point, in KiB (`--prefetch-buffer-size`).
  ///
  /// Read-ahead, which is a different thing from [networkCaching]. Caching is
  /// output latency - every stream has to fill it before it emits, so raising
  /// it delays a newly selected audio or subtitle track by exactly that long.
  /// This buffer sits under the demuxer instead, so a larger one costs memory
  /// and nothing else, and it is what makes a seek land without going back to
  /// the network. The window serves reads in both directions, so it covers a
  /// skip backwards as well as forwards.
  ///
  /// Setting this also asks for the `prefetch` stream filter, which libVLC
  /// does not select on its own. The filter declines local files, where the
  /// operating system's own cache does better, and PID-filtered streams, where
  /// it would add latency - both cleanly, so this is inert rather than harmful
  /// where it does not apply.
  final int? prefetchBufferKiB;

  /// Emits the `--…` options this config represents.
  List<String> toOptions() {
    return <String>[
      if (networkCaching != null) '--network-caching=$networkCaching',
      if (liveCaching != null) '--live-caching=$liveCaching',
      if (fileCaching != null) '--file-caching=$fileCaching',
      if (userAgent != null && userAgent!.isNotEmpty)
        '--http-user-agent=$userAgent',
      if (referer != null && referer!.isNotEmpty) '--http-referrer=$referer',
      if (adaptiveLogic != null) '--adaptive-logic=${adaptiveLogic!._value}',
      if (adaptiveMaxHeight != null) '--adaptive-maxheight=$adaptiveMaxHeight',
      // The filter scores 0, so naming it is the only way it is ever selected.
      if (prefetchBufferKiB != null) ...<String>[
        '--stream-filter=prefetch',
        '--prefetch-buffer-size=$prefetchBufferKiB',
      ],
    ];
  }
}

/// Decoder behaviour.
@immutable
class VlcDecodingConfig {
  const VlcDecodingConfig({
    this.hardwareAcceleration = VlcHardwareAcceleration.platformDefault,
    this.decodeThrift = VlcDecodeThrift.none,
    this.dropLateFrames,
    this.threads,
  });

  /// Hardware decoding preference (`--avcodec-hw`).
  ///
  /// Honoured on Android and Darwin, inert on Windows and Linux. Those two
  /// render through the vmem callbacks, and `libvlc_video_set_callbacks` sets
  /// `avcodec-hw = "none"` on the media player as it installs them (VLC 3.0.21
  /// `lib/media_player.c`:1113). `var_Inherit` stops at the first object
  /// holding the variable (`src/misc/variables.c`:1177), and the media player
  /// sits below the instance in the decoder's chain, so the instance-level
  /// option emitted here is never reached. A per-media option would win, since
  /// those attach to the input thread, but nothing sets one today.
  ///
  /// Darwin keeps its hardware path either way: VideoToolbox is a standalone
  /// decoder module in VLC 3 (`modules/codec/videotoolbox.m`), not an avcodec
  /// accelerator, so `avcodec-hw` has no authority over it.
  final VlcHardwareAcceleration hardwareAcceleration;

  /// How much decode work may be skipped when running behind.
  final VlcDecodeThrift decodeThrift;

  /// Whether to drop frames that arrive too late (`--drop-late-frames`).
  ///
  /// Leaving this null uses VLC's default (enabled). Disabling it favours
  /// completeness over smoothness.
  final bool? dropLateFrames;

  /// Decoder thread count (`--avcodec-threads`). 0 lets VLC choose.
  final int? threads;

  /// Emits the `--…` options this config represents.
  List<String> toOptions() {
    // --avcodec-skiploopfilter: 0 none, 1 non-ref, 2 bidir, 3 non-key, 4 all.
    // --avcodec-skip-frame:     0 none, 1 non-ref, 2 bidir, 3 non-key, 4 all.
    final (int loopFilter, int skipFrame) = switch (decodeThrift) {
      VlcDecodeThrift.none => (0, 0),
      VlcDecodeThrift.light => (1, 0),
      VlcDecodeThrift.aggressive => (3, 1),
    };

    return <String>[
      switch (hardwareAcceleration) {
        VlcHardwareAcceleration.automatic => '--avcodec-hw=any',
        VlcHardwareAcceleration.disabled => '--avcodec-hw=none',
        VlcHardwareAcceleration.platformDefault => '',
      },
      if (decodeThrift != VlcDecodeThrift.none) ...<String>[
        '--avcodec-skiploopfilter=$loopFilter',
        '--avcodec-skip-frame=$skipFrame',
      ],
      if (dropLateFrames != null)
        dropLateFrames! ? '--drop-late-frames' : '--no-drop-late-frames',
      if (threads != null) '--avcodec-threads=$threads',
    ]..removeWhere((option) => option.isEmpty);
  }
}

/// Where a subtitle sits on screen.
enum VlcSubtitleAlignment {
  left,
  center,
  right;

  /// `--freetype-text-align` value.
  String get _value => switch (this) {
    VlcSubtitleAlignment.left => 'left',
    VlcSubtitleAlignment.center => 'center',
    VlcSubtitleAlignment.right => 'right',
  };
}

/// Appearance of VLC-rendered subtitles.
///
/// These are libVLC instance options: VLC 3.x cannot restyle subtitles on a
/// running player, so changing a style means creating a new player. A host
/// that needs live restyling renders subtitles itself instead.
@immutable
class VlcSubtitleStyle {
  const VlcSubtitleStyle({
    this.fontFamily,
    this.fontSize,
    this.relativeFontSize,
    this.color,
    this.bold,
    this.outlineColor,
    this.outlineThickness,
    this.shadowColor,
    this.shadowDistance,
    this.backgroundColor,
    this.marginPixels,
    this.alignment,
    this.autoDetectFiles,
  });

  /// Font family name (`--freetype-font`).
  final String? fontFamily;

  /// Absolute size in pixels (`--freetype-fontsize`). 0 means auto.
  ///
  /// Prefer [relativeFontSize] — an absolute size that suits a phone is
  /// unreadable on a television.
  final int? fontSize;

  /// Size relative to video height (`--freetype-rel-fontsize`).
  ///
  /// VLC's own scale: smaller numbers mean larger text (20 is roughly
  /// "large", 16 "larger"). This scales correctly across form factors.
  final int? relativeFontSize;

  /// Text colour (`--freetype-color` + `--freetype-opacity`).
  final Color? color;

  /// Whether to embolden (`--freetype-bold`).
  final bool? bold;

  /// Outline colour (`--freetype-outline-color` + opacity).
  final Color? outlineColor;

  /// Outline thickness in pixels (`--freetype-outline-thickness`).
  final int? outlineThickness;

  /// Drop-shadow colour (`--freetype-shadow-color` + opacity).
  final Color? shadowColor;

  /// Drop-shadow distance (`--freetype-shadow-distance`).
  final int? shadowDistance;

  /// Box colour behind the text (`--freetype-background-color` + opacity).
  final Color? backgroundColor;

  /// Distance from the bottom of the video, in pixels (`--sub-margin`).
  final int? marginPixels;

  /// Horizontal alignment (`--freetype-text-align`).
  final VlcSubtitleAlignment? alignment;

  /// Whether VLC should auto-load sidecar subtitle files next to the media
  /// (`--sub-autodetect-file`).
  ///
  /// Off keeps VLC from adding tracks the host's own subtitle list does not
  /// know about.
  final bool? autoDetectFiles;

  /// VLC colour options take a 24-bit integer; opacity is a separate 0-255.
  static int _rgb(Color color) {
    final int r = (color.r * 255.0).round() & 0xff;
    final int g = (color.g * 255.0).round() & 0xff;
    final int b = (color.b * 255.0).round() & 0xff;
    return (r << 16) | (g << 8) | b;
  }

  static int _alpha(Color color) => (color.a * 255.0).round() & 0xff;

  /// Emits the `--…` options this style represents.
  List<String> toOptions() {
    return <String>[
      if (fontFamily != null && fontFamily!.isNotEmpty)
        '--freetype-font=$fontFamily',
      if (fontSize != null) '--freetype-fontsize=$fontSize',
      if (relativeFontSize != null) '--freetype-rel-fontsize=$relativeFontSize',
      if (color != null) ...<String>[
        '--freetype-color=${_rgb(color!)}',
        '--freetype-opacity=${_alpha(color!)}',
      ],
      if (bold != null) bold! ? '--freetype-bold' : '--no-freetype-bold',
      if (outlineColor != null) ...<String>[
        '--freetype-outline-color=${_rgb(outlineColor!)}',
        '--freetype-outline-opacity=${_alpha(outlineColor!)}',
      ],
      if (outlineThickness != null)
        '--freetype-outline-thickness=$outlineThickness',
      if (shadowColor != null) ...<String>[
        '--freetype-shadow-color=${_rgb(shadowColor!)}',
        '--freetype-shadow-opacity=${_alpha(shadowColor!)}',
      ],
      if (shadowDistance != null) '--freetype-shadow-distance=$shadowDistance',
      if (backgroundColor != null) ...<String>[
        '--freetype-background-color=${_rgb(backgroundColor!)}',
        '--freetype-background-opacity=${_alpha(backgroundColor!)}',
      ],
      if (marginPixels != null) '--sub-margin=$marginPixels',
      if (alignment != null) '--freetype-text-align=${alignment!._value}',
      if (autoDetectFiles != null)
        autoDetectFiles! ? '--sub-autodetect-file' : '--no-sub-autodetect-file',
    ];
  }
}

/// Top-level VLC instance configuration.
///
/// Compose the groups you care about and pass `config.toOptions()` as the
/// controller's `options`. Groups left null contribute nothing, so VLC's own
/// defaults apply.
@immutable
class VlcPlayerConfig {
  const VlcPlayerConfig({
    this.network,
    this.decoding,
    this.subtitleStyle,
    this.showVideoTitle = false,
    this.verbose = false,
    this.backgroundPolicy,
    this.darwinRenderer = defaultDarwinRenderer,
    this.androidRenderer = defaultAndroidRenderer,
    this.extraOptions = const <String>[],
  });

  /// Network and HTTP behaviour.
  final VlcNetworkConfig? network;

  /// Decoder behaviour.
  final VlcDecodingConfig? decoding;

  /// Appearance of VLC-rendered subtitles.
  final VlcSubtitleStyle? subtitleStyle;

  /// Whether VLC overlays the media title when playback starts.
  ///
  /// Off by default: an embedded player draws its own title, and VLC's overlay
  /// appears on top of it.
  final bool showVideoTitle;

  /// Whether to raise libVLC log verbosity. Defaults to quiet.
  final bool verbose;

  /// What to do with playback when the app leaves the foreground.
  ///
  /// Null defers to [platformDefaultBackgroundPolicy]. Contributes nothing to
  /// [toOptions]; the controller reads it directly.
  final VlcBackgroundPolicy? backgroundPolicy;

  /// The policy a platform gets when the host expresses no preference.
  ///
  /// Mobile pauses: a backgrounded app that keeps decoding burns battery on
  /// frames nobody can see, with no notification to stop the audio. Desktop
  /// keeps playing, because a window behind another window is still audible.
  static VlcBackgroundPolicy get platformDefaultBackgroundPolicy =>
      switch (defaultTargetPlatform) {
        TargetPlatform.android ||
        TargetPlatform.iOS => VlcBackgroundPolicy.pause,
        _ => VlcBackgroundPolicy.keepPlaying,
      };

  /// How video reaches the screen on macOS and iOS.
  ///
  /// Not a libVLC option. Hosts pass it on to [VlcPlayer.darwinRenderer],
  /// because the controller keeps the flattened option list rather than the
  /// config. Android has [androidRenderer]; Windows and Linux have a single
  /// renderer and ignore both.
  final VlcDarwinRenderer darwinRenderer;

  /// The renderer macOS and iOS get when the host expresses no preference.
  ///
  /// The texture, because the platform view flickers: every Flutter layer
  /// drawn over an AppKitView or UiKitView becomes an embedder overlay
  /// surface, and repainting one can drop the video for a frame.
  static const VlcDarwinRenderer defaultDarwinRenderer =
      VlcDarwinRenderer.texture;

  /// How video reaches the screen on Android.
  ///
  /// The Android counterpart of [darwinRenderer], and like it not a libVLC
  /// option: hosts pass it on to [VlcPlayer.androidRenderer].
  final VlcAndroidRenderer androidRenderer;

  /// The renderer Android gets when the host expresses no preference.
  ///
  /// The platform view, deliberately, even though the texture is the default
  /// everywhere else: a single-surface texture costs libVLC 3 its hardware
  /// decoder. `android/display.c` refuses to open on an opaque MediaCodec
  /// surface with nowhere to blend subtitles, the MediaCodec module then fails
  /// its opaque vout request, and playback falls back to avcodec software
  /// decode. VLCVideoLayout avoids that by attaching a second TextureView for
  /// subtitles. Two more blockers sit behind it: Flutter's
  /// ImageReaderSurfaceProducer reports `handlesCropAndRotation() == false`,
  /// so hardware-decoded 1920x1088 buffers render their padding rows, and the
  /// texture path drops the sample aspect ratio the view honours.
  ///
  /// The texture target stays selectable through
  /// [VlcPlayerConfig.androidRenderer] as the base for a second
  /// SurfaceProducer for subtitles. Do not flip this default until a device
  /// shows `mediacodec_ndk` in the libVLC log with the texture selected.
  static const VlcAndroidRenderer defaultAndroidRenderer =
      VlcAndroidRenderer.platformView;

  /// [backgroundPolicy], resolved against the platform default.
  ///
  /// A getter rather than a constructor-time value: [VlcPlayerConfig] is
  /// const-constructible and `defaultTargetPlatform` is overridable, so
  /// resolving early would bake in whatever platform was current when the
  /// config literal was evaluated.
  VlcBackgroundPolicy get effectiveBackgroundPolicy =>
      backgroundPolicy ?? platformDefaultBackgroundPolicy;

  /// Raw options appended verbatim, last, so they win over generated options.
  final List<String> extraOptions;

  /// Builds the complete option list, in precedence order.
  List<String> toOptions() {
    return <String>[
      if (!showVideoTitle) '--no-video-title-show',
      if (verbose) '--verbose=2' else '--quiet',
      ...?network?.toOptions(),
      ...?decoding?.toOptions(),
      ...?subtitleStyle?.toOptions(),
      ...extraOptions,
    ];
  }

  /// Returns a copy with the given fields replaced.
  VlcPlayerConfig copyWith({
    VlcNetworkConfig? network,
    VlcDecodingConfig? decoding,
    VlcSubtitleStyle? subtitleStyle,
    bool? showVideoTitle,
    bool? verbose,
    VlcBackgroundPolicy? backgroundPolicy,
    VlcDarwinRenderer? darwinRenderer,
    VlcAndroidRenderer? androidRenderer,
    List<String>? extraOptions,
  }) {
    return VlcPlayerConfig(
      network: network ?? this.network,
      decoding: decoding ?? this.decoding,
      subtitleStyle: subtitleStyle ?? this.subtitleStyle,
      showVideoTitle: showVideoTitle ?? this.showVideoTitle,
      verbose: verbose ?? this.verbose,
      backgroundPolicy: backgroundPolicy ?? this.backgroundPolicy,
      darwinRenderer: darwinRenderer ?? this.darwinRenderer,
      androidRenderer: androidRenderer ?? this.androidRenderer,
      extraOptions: extraOptions ?? this.extraOptions,
    );
  }
}

/// What a libVLC-backed player can and cannot do, for hosts that support more
/// than one playback engine.
abstract final class VlcPlayerCapabilities {
  /// Highest volume accepted by `setVolume`, as a percentage.
  ///
  /// libVLC amplifies above 100%, unlike the platform-native players on most
  /// systems.
  static const int maxVolumePercent = 200;

  /// Whether the engine can offset subtitles against video.
  static const bool supportsSubtitleDelay = true;

  /// Whether the engine can offset audio against video.
  static const bool supportsAudioDelay = true;

  /// Whether the engine can load a subtitle file that is not in the container.
  static const bool supportsExternalSubtitles = true;

  /// Whether subtitle appearance can be changed while a player is running.
  ///
  /// False for VLC 3.x: styling is fixed at instance creation. See
  /// [VlcSubtitleStyle].
  static const bool supportsRuntimeSubtitleStyling = false;

  /// Whether the engine reports HDR metadata or performs tone mapping.
  ///
  /// False: libVLC exposes no tone-mapping controls comparable to mpv's
  /// `vo_gpu`.
  static const bool supportsToneMapping = false;

  /// Playback-rate bounds accepted by `setPlaybackSpeed`.
  static const double minPlaybackSpeed = 0.25;
  static const double maxPlaybackSpeed = 4.0;
}
