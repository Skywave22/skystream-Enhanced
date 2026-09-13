/// Typed configuration that compiles to libVLC command-line options.
///
/// The controller accepts a raw `List<String> options`, which is flexible but
/// pushes every caller into hand-writing VLC option strings, remembering their
/// exact spelling, and re-deriving the same defaults. Everything in this file
/// is a typed, documented stand-in for that: build a [VlcPlayerConfig], call
/// [VlcPlayerConfig.toOptions], and pass the result.
///
/// Nothing here is app-specific — these are plain VLC concepts, so the same
/// config works for any host application.
///
/// Raw options remain fully supported and are never removed; a config is
/// merged with, not a replacement for, [VlcPlayerConfig.extraOptions].
library;

import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

/// Hardware-accelerated decoding preference, mapped to `--avcodec-hw`.
enum VlcHardwareAcceleration {
  /// Let VLC pick a hardware decoder if one is available (`any`).
  automatic,

  /// Force software decoding (`none`).
  ///
  /// Useful as a fallback after a hardware decoder has failed for the current
  /// session — some low-end decoders fail only on specific codec profiles.
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
/// The one entry in [VlcPlayerConfig] that is not a libVLC option. libVLC has
/// no notion of an application lifecycle, so somebody has to hold this policy;
/// holding it here means every embedder inherits the same answer instead of
/// each one re-deriving it from `Platform` in its own screen.
enum VlcBackgroundPolicy {
  /// Pause on the way out, and resume on the way back.
  ///
  /// The resume is conditional on this policy having been what paused it. A
  /// viewer who paused deliberately and then pressed Home comes back to a
  /// paused player, which is what they left.
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
  /// The path that shipped first, kept one flag away. Its cost is that any
  /// Flutter widget drawn above the video forces the embedder to composite
  /// Flutter content over a native view - on macOS by slicing the overlay
  /// into IOSurfaces every frame, on iOS through the equivalent overlay
  /// layers - and that composite can drop the video for a frame.
  platformView,

  /// A Flutter `Texture` fed from a CVPixelBuffer pool.
  ///
  /// Puts the video back inside the Flutter layer tree, so controls painted
  /// over it are ordinary Flutter painting. One renderer serves both
  /// platforms; see [VlcPlayerConfig.defaultDarwinRenderer] for what has been
  /// measured where.
  texture,
}

/// How the video surface reaches the screen on Android.
enum VlcAndroidRenderer {
  /// A native platform view (`AndroidView`) holding a `VLCVideoLayout`.
  ///
  /// The path that shipped first, kept one flag away. It does not flicker -
  /// Flutter composites the view through a texture of its own - but it pays
  /// for that with two full-frame compositions per frame (MediaCodec into the
  /// layout's TextureView, then the view into Flutter), a frame of latency,
  /// the platform view's input plumbing, and a focus node the widget has to
  /// exclude from traversal.
  platformView,

  /// A Flutter `Texture` fed straight from the decoder.
  ///
  /// libVLC draws into a surface the engine owns, so the video is composited
  /// once, with everything else in the frame, and fit and clipping are
  /// ordinary widget layout - the same Dart path Windows, Linux and the Darwin
  /// texture use. Subtitles are blended into the picture by libVLC because
  /// there is no second surface for them.
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
  /// inheritance, so this is the fallback for sources that carry none. Many
  /// CDNs reject the stock libVLC agent, so setting a browser agent here is a
  /// common need.
  final String? userAgent;

  /// Default `Referer` for HTTP media (`--http-referrer`).
  final String? referer;

  /// Rendition-selection strategy for HLS/DASH (`--adaptive-logic`).
  final VlcAdaptiveLogic? adaptiveLogic;

  /// Cap on adaptive rendition height, e.g. 1080 (`--adaptive-maxheight`).
  ///
  /// Pinning this below the panel resolution is an effective way to keep a
  /// weak device from selecting a rendition it cannot decode.
  final int? adaptiveMaxHeight;

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
  /// Honoured on Android and Darwin. **Inert on Windows and Linux**, and the
  /// reason is libVLC's, not this plugin's: those two render through the vmem
  /// callbacks, and `libvlc_video_set_callbacks` sets `avcodec-hw = "none"` on
  /// the media player as it installs them (VLC 3.0.21 `lib/media_player.c`:
  /// 1113, unchanged across every 3.0.x tag). `var_Inherit` walks child to
  /// parent and stops at the first object holding the variable
  /// (`src/misc/variables.c`:1177), and the decoder's chain is decoder →
  /// input → media player → instance, so the media player's `"none"` is found
  /// before the instance-level option this emits is ever reached.
  ///
  /// libVLC means it. `libvlc_media_player_set_nsobject`, `set_xwindow` and
  /// `set_hwnd` each put `avcodec-hw` back to `""` (`:1143`, `:1200`, `:1222`)
  /// precisely because those paths have a real window to decode into. The
  /// model is "native window ⇒ hardware decode allowed; vmem ⇒ never".
  ///
  /// Two things follow, and both have been reasoned about wrongly here before.
  /// There is no hardware-surface-into-a-vmem-output mismatch to be had on
  /// Windows or Linux, because the combination cannot be constructed. And
  /// turning hardware decoding *off* on those platforms costs nothing, because
  /// it was never on - so a null result from that experiment says nothing
  /// about whether hardware decode was implicated.
  ///
  /// Darwin keeps its hardware path regardless: VideoToolbox is a standalone
  /// `video decoder` module in VLC 3 (`modules/codec/videotoolbox.m`,
  /// capability 800), not an avcodec hardware accelerator, so `avcodec-hw` has
  /// no authority over it. On Windows and Linux the hardware decoders are
  /// DXVA2/D3D11VA and VA-API/VDPAU, which *are* avcodec accelerators, and are
  /// therefore exactly what this shuts off.
  ///
  /// A per-media option would win if hardware decode is ever wanted on those
  /// platforms - media options attach to the input thread, a child of the
  /// media player - but nothing does that today.
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
/// Note that these are libVLC *instance* options: VLC 3.x cannot restyle
/// subtitles on an already-running player, so changing a style means creating
/// a new player. A host that needs live restyling should render subtitles
/// itself and leave VLC's renderer disabled.
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
  /// Hosts that manage their own subtitle list usually want this off, so VLC
  /// does not silently add tracks the host does not know about.
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
  /// Defaults to false: an embedded player almost always draws its own title,
  /// and VLC's overlay appears on top of it.
  final bool showVideoTitle;

  /// Whether to raise libVLC log verbosity. Defaults to quiet.
  final bool verbose;

  /// What to do with playback when the app leaves the foreground.
  ///
  /// Null defers to [platformDefaultBackgroundPolicy], which is what most
  /// hosts want. Set it only where the app genuinely disagrees with its
  /// platform — a podcast player on Android, say.
  ///
  /// Unlike everything else here this contributes nothing to [toOptions]; the
  /// controller reads it directly.
  final VlcBackgroundPolicy? backgroundPolicy;

  /// The policy a platform gets when the host expresses no preference.
  ///
  /// Mobile pauses. A backgrounded Android or iOS app that keeps libVLC
  /// decoding is burning battery on frames nobody can see and playing audio
  /// the user has no notification to stop.
  ///
  /// Desktop keeps playing. A window behind another window is still a window
  /// somebody is listening to, and cmd-tab must not stop the film.
  static VlcBackgroundPolicy get platformDefaultBackgroundPolicy =>
      switch (defaultTargetPlatform) {
        TargetPlatform.android ||
        TargetPlatform.iOS => VlcBackgroundPolicy.pause,
        _ => VlcBackgroundPolicy.keepPlaying,
      };

  /// How video reaches the screen on macOS and iOS.
  ///
  /// The second entry here that is not a libVLC option. Hosts pass it on to
  /// [VlcPlayer.darwinRenderer]; the widget cannot read it from the controller
  /// because the controller keeps the flattened option list, not the config.
  ///
  /// Honoured on macOS and iOS. Android has its own switch in
  /// [androidRenderer]; Windows and Linux have a single renderer and ignore
  /// both.
  final VlcDarwinRenderer darwinRenderer;

  /// The renderer a Darwin platform gets when the host expresses no
  /// preference. Both macOS and iOS consult it.
  ///
  /// The texture, because the platform view flickers. Every Flutter layer
  /// drawn over an AppKitView becomes an embedder overlay surface, and any
  /// repaint of one - a hovered button, a fading bar - can drop the video for
  /// a frame, showing whatever is painted beneath it. Measured on a 5K
  /// display, 1080p and 4K, 2026-09-06: platform view flickered on every
  /// control interaction and flashed the backdrop at startup; the texture did
  /// neither. iOS follows the same default because a UiKitView carries the
  /// identical compositing cost and the renderer behind the texture is the
  /// one just verified - and on iOS it has run on the simulator (frames, no
  /// green band, clean close) but not yet on a device, where VideoToolbox
  /// differs. Flipping this constant is the single switch for every host.
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
  /// everywhere else. A single-surface texture costs libVLC 3 its hardware
  /// decoder: `android/display.c` refuses to open on an opaque MediaCodec
  /// surface with nowhere to blend subtitles ("cannot blend subtitles with an
  /// opaque surface, trying next vout"), the MediaCodec module then fails
  /// ("Opaque Vout request failed") and playback falls back to avcodec
  /// software decode - which on a Chromecast turns 1080p into a stutter and
  /// 4K into nothing. VLCVideoLayout avoids this by attaching a second
  /// TextureView for subtitles, and that is the only reason the platform view
  /// keeps hardware decode. Two more blockers sit behind that one: Flutter's
  /// ImageReaderSurfaceProducer reports `handlesCropAndRotation() == false`, so
  /// hardware-decoded 1920x1088 buffers would render their padding rows; and
  /// the texture path drops the sample aspect ratio the view honours.
  ///
  /// The texture target stays in the tree as the base for the real fix - a
  /// second SurfaceProducer for subtitles, mirroring VLCVideoLayout - and is
  /// selectable through [VlcPlayerConfig.androidRenderer] for that work. Do
  /// not flip this until a device shows `mediacodec_ndk` in the libVLC log
  /// with the texture selected.
  static const VlcAndroidRenderer defaultAndroidRenderer =
      VlcAndroidRenderer.platformView;

  /// [backgroundPolicy], resolved against the platform default.
  ///
  /// Deliberately a getter rather than a value settled in the constructor:
  /// [VlcPlayerConfig] is const-constructible, and `defaultTargetPlatform` is
  /// overridable, so resolving early would bake in whatever platform happened
  /// to be current when the config literal was evaluated.
  VlcBackgroundPolicy get effectiveBackgroundPolicy =>
      backgroundPolicy ?? platformDefaultBackgroundPolicy;

  /// Raw options appended verbatim, after everything above.
  ///
  /// The escape hatch: anything this class does not model can still be passed,
  /// and because these come last they win over the generated options.
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

/// What a libVLC-backed player can and cannot do.
///
/// Hosts that support more than one playback engine tend to hard-code these
/// limits at the call site, which then drifts. Reading them from here keeps
/// the capability description next to the implementation it describes.
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
  /// False for VLC 3.x: styling is fixed at instance creation, so a host that
  /// offers live restyling must recreate the player or render its own
  /// subtitles. See [VlcSubtitleStyle].
  static const bool supportsRuntimeSubtitleStyling = false;

  /// Whether the engine reports HDR metadata or performs tone mapping.
  ///
  /// False: libVLC exposes no tone-mapping controls comparable to mpv's
  /// `vo_gpu`. A host with HDR settings should hide them for this engine.
  static const bool supportsToneMapping = false;

  /// Playback-rate bounds accepted by `setPlaybackSpeed`.
  static const double minPlaybackSpeed = 0.25;
  static const double maxPlaybackSpeed = 4.0;
}
