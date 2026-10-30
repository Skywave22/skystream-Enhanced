/// What libVLC is told for the whole player and for each media (spec 1.1,
/// 1.3, 1.6, 1.7 and 1.9), and how the buffer plan (1.2) reaches it.
///
/// Per media wherever an option allows it: libvlc-android adds its own
/// `:network-caching=1500` and `:file-caching=1500` to every media that
/// doesn't carry them, so only a media option makes Android follow the app.
library;

import 'package:flutter/foundation.dart';

import 'network_buffer.dart';

/// libVLC's start threshold for video on demand: files, HLS, DASH and LAN
/// servers. HLS and DASH ignore it; libVLC fixes their delay at 1 s.
const int kVodCachingMs = 1000;

/// The same for live TS, UDP, RTP and RTSP. A feed can't read ahead, so it
/// gets half a second more slack for jitter.
const int kLiveCachingMs = 1500;

/// How far behind the live edge live HLS and DASH start: libVLC's default is
/// 15 s, and it won't go under its 6 s minimum buffer. Measured on a jittery
/// link on macOS and Android (P1 plan, Task 17), no delay from 6 to 15 s
/// stalled, and 6 and 8 s started equally close on 4 s segments; libVLC also
/// buffers a live stream no further than this, so the owner chose 8 s over the
/// thinnest buffer (2026-10-13).
const int kLiveDelayMs = 8000;

/// Whether [uri] names a DASH manifest, directly or through the local proxy,
/// which carries the real address in its query.
bool looksLikeDash(Uri uri) {
  final path = uri.path.toLowerCase();
  return path.endsWith('.mpd') || uri.query.toLowerCase().contains('.mpd');
}

/// Whether a media decodes in software: Android with the hardware switch off.
///
/// `:codec=all` is libvlc-android's own "hardware off". The switch reaches
/// nothing elsewhere: Windows and Linux decode in software whatever it says,
/// and Darwin's VideoToolbox is a decoder module of its own.
bool softwareDecodeFor({
  required TargetPlatform platform,
  required bool hardwareDecoding,
}) => platform == TargetPlatform.android && !hardwareDecoding;

/// Options for the whole player, by platform.
List<String> playerInstanceOptions(TargetPlatform platform) =>
    switch (platform) {
      // AudioTrack first: libvlc-android otherwise picks OpenSL ES on Amazon
      // devices, which is stereo only. OpenSL ES stays as the fallback for an
      // AudioTrack that can't open.
      TargetPlatform.android => const <String>[
        '--aout=android_audiotrack,opensles',
      ],
      // Both convert every frame to RGBA on the CPU; fast bilinear measured
      // half as many frames again at 4K.
      TargetPlatform.windows ||
      TargetPlatform.linux => const <String>['--swscale-mode=0'],
      _ => const <String>[],
    };

/// The options for one media.
///
/// - [live]: a live feed starts on [kLiveCachingMs], and live HLS and DASH
///   [liveDelayMs] behind the edge (TS and UDP ignore the delay);
/// - [plan]: the read-ahead of a file or a torrent, the buffer of HLS or DASH;
/// - [renditionCap]: the height cap, when it isn't the one the player was
///   created with;
/// - [qualityPicked]: a Quality pick plays its height exactly, so libVLC's
///   `highest` replaces the player's `predictive` for this media;
/// - [softwareDecode]: see [softwareDecodeFor];
/// - [languageOption]: the audio language setting, when it speaks for this
///   media;
/// - [audioSlave]: the address of a sound that is in a file of its own, which
///   libVLC plays with the video when it is named as the media's second input.
List<String> playbackMediaOptions({
  required bool live,
  required BufferPlan plan,
  int? renditionCap,
  bool qualityPicked = false,
  bool softwareDecode = false,
  String? languageOption,
  String? audioSlave,
  int liveDelayMs = kLiveDelayMs,
}) => <String>[
  ':network-caching=${live ? kLiveCachingMs : kVodCachingMs}',
  if (live) ':adaptive-livedelay=$liveDelayMs',
  if (plan.ringMb case final mb?) ':prefetch-buffer-size=${mb * 1024}',
  if (plan.adaptiveSeconds case final seconds?)
    ':adaptive-maxbuffer=${seconds * 1000}',
  if (renditionCap != null) ':adaptive-maxheight=$renditionCap',
  if (qualityPicked) ':adaptive-logic=highest',
  if (softwareDecode) ':codec=all',
  ?languageOption,
  ?audioSlave,
];
