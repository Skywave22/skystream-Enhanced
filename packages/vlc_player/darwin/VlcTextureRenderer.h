#import <TargetConditionals.h>

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

// The one copy of this renderer, compiled into both Darwin pods. ios/ and
// macos/ each carry a symlink to it inside their Sources tree because
// CocoaPods only globs inside the pod root, so a `../darwin/**` entry in
// source_files matches nothing. The embedder header is the only line that
// differs between the two platforms.
#if TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#else
#import <Flutter/Flutter.h>
#endif

NS_ASSUME_NONNULL_BEGIN

@class VLCMediaPlayer;

/// A Flutter texture fed straight out of libVLC into a CVPixelBuffer pool.
///
/// The alternative, a platform view, forces the embedder to slice every
/// Flutter widget drawn above the video into its own overlay surface. A
/// texture keeps the video inside the Flutter layer tree, where the controls
/// above it are just more painting.
///
/// Attaching one of these replaces the media player's drawable: a player is
/// either view-backed or texture-backed, never both.
@interface VlcTextureRenderer : NSObject <FlutterTexture>

/// Installs libVLC's video callbacks on `mediaPlayer`.
///
/// Must be called before the player is given media, since libVLC settles the
/// video output when playback starts.
- (instancetype)initWithMediaPlayer:(VLCMediaPlayer *)mediaPlayer
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Invoked from libVLC's video thread whenever a new frame is ready.
///
/// Set after the texture has been registered, because the registry hands back
/// the id this block has to name.
@property(nonatomic, copy, nullable) void (^onFrameAvailable)(void);

/// The chroma libVLC was asked to deliver, for diagnostics.
@property(nonatomic, readonly) NSString *chroma;

/// The exact pixel dimensions libVLC is decoding into, or zero before the
/// first Configure.
///
/// This is the size to hand Flutter for aspect and layout. `VLCMediaPlayer`'s
/// own `videoSize` is measured from its drawable, and a texture-backed player
/// has no drawable, so it reports 0 or a stale value.
@property(nonatomic, readonly) CGSize codedSize;

/// Stops libVLC calling in and drops every retained frame. Idempotent, and
/// required before the media player is torn down.
- (void)detach;

@end

NS_ASSUME_NONNULL_END
