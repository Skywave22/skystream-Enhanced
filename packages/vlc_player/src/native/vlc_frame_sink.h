#ifndef VLC_PLAYER_NATIVE_VLC_FRAME_SINK_H_
#define VLC_PLAYER_NATIVE_VLC_FRAME_SINK_H_

#include <cstdint>

namespace vlc_player {

// libVLC hands out at most this many planes per picture.
inline constexpr int kVlcMaxPlanes = 3;

// The picture layout being negotiated with libVLC.
//
// `chroma` is in/out: libVLC proposes the source chroma and the sink writes
// back the FourCC it wants to be handed. Everything else is out-only.
struct VlcFrameFormat {
  char chroma[5] = {};
  uint32_t width = 0;
  uint32_t height = 0;
  uint32_t pitches[kVlcMaxPlanes] = {};
  uint32_t lines[kVlcMaxPlanes] = {};
};

// Where decoded frames go.
//
// One implementation per presentation strategy: VlcPixelBufferSink keeps CPU
// buffers for Flutter's pixel-buffer textures on Windows and Linux, and the
// Darwin sink fills CVPixelBuffers out of a pool. Splitting this out of
// VlcPlayerCore lets a platform choose its own presentation without forking
// the player.
//
// The five entry points are libVLC 3's video callbacks under names that also
// fit libVLC 4's GPU output callbacks: Configure/Cleanup are 4's
// setup/cleanup, and Commit is its swap.
//
// Threading: every method is called on libVLC's video output thread, one
// picture at a time. The sink is responsible for whatever locking its
// consumer side needs.
class VlcFrameSink {
 public:
  virtual ~VlcFrameSink() = default;

  // Negotiates the picture layout. Returns the number of planes the sink
  // filled in, or 0 to refuse the format.
  virtual uint32_t Configure(VlcFrameFormat* format) = 0;

  // Releases whatever Configure allocated.
  virtual void Cleanup() = 0;

  // Hands libVLC writable plane base addresses. Returns an opaque picture
  // token that comes back to Commit and Release, or nullptr to drop the frame.
  virtual void* Acquire(void** planes) = 0;

  // Marks `picture` as the frame that should become visible.
  //
  // libVLC calls this only for pictures it actually displays, and with the
  // single-picture pool that libVLC 3's vmem output uses it may arrive either
  // side of Release. A sink with work to do at both points must tolerate both
  // orders.
  virtual void Commit(void* picture) = 0;

  // libVLC has finished writing `picture`.
  virtual void Release(void* picture, void* const* planes) = 0;
};

}  // namespace vlc_player

#endif  // VLC_PLAYER_NATIVE_VLC_FRAME_SINK_H_
