#ifndef VLC_PLAYER_NATIVE_VLC_PIXEL_BUFFER_SINK_H_
#define VLC_PLAYER_NATIVE_VLC_PIXEL_BUFFER_SINK_H_

#include <cstddef>
#include <cstdint>
#include <functional>
#include <mutex>
#include <vector>

#include "vlc_frame_sink.h"

namespace vlc_player {

// A triple-buffered RGBA sink for Flutter's CPU pixel-buffer textures.
//
// Used by the Windows and Linux embedders, both of which upload the pointer
// handed back by CopyPixels synchronously - flutter_windows copies it into a
// staging texture inside the callback, and the GTK embedder glTexImage2Ds it
// inside fl_pixel_buffer_texture_populate. That synchronous consumption is
// what the buffer rotation below relies on.
class VlcPixelBufferSink final : public VlcFrameSink {
 public:
  // `on_frame_available` is invoked from libVLC's video thread each time a
  // frame is displayed, and must be cheap.
  explicit VlcPixelBufferSink(std::function<void()> on_frame_available);
  ~VlcPixelBufferSink() override;

  uint32_t Configure(VlcFrameFormat* format) override;
  void Cleanup() override;
  void* Acquire(void** planes) override;
  void Commit(void* picture) override;
  void Release(void* picture, void* const* planes) override;

  // Hands the newest complete frame to the embedder. False when nothing has
  // been decoded yet, in which case the out parameters are untouched.
  bool CopyPixels(const uint8_t** out_buffer, uint32_t* width,
                  uint32_t* height);

  // The negotiated picture size, zero until Configure has run.
  void FrameSize(uint32_t* width, uint32_t* height) const;

#ifdef VLC_PLAYER_TESTING
  void ResizeForTesting(uint32_t width, uint32_t height, uint32_t pitch);
  void SimulateFrameForTesting(uint8_t value);
  const uint8_t* FrameBufferDataForTesting() const;
  size_t FrameBufferSizeForTesting() const;
  const uint8_t* TextureBufferDataForTesting() const;
  const uint8_t* RetiredBufferDataForTesting() const;
  size_t RetiredBufferSizeForTesting() const;
  uint64_t RenderGenerationForTesting() const;
  uint64_t TextureGenerationForTesting() const;
#endif  // VLC_PLAYER_TESTING

 private:
  void Resize(uint32_t width, uint32_t height, uint32_t pitch);

  std::function<void()> on_frame_available_;

  mutable std::mutex mutex_;
  // Rotated, never copied. frame_buffer_ is what libVLC writes into,
  // render_buffer_ holds the newest complete frame, and texture_buffer_ is
  // whatever the embedder was last handed.
  std::vector<uint8_t> frame_buffer_;
  std::vector<uint8_t> render_buffer_;
  std::vector<uint8_t> texture_buffer_;
  // The texture_buffer_ a format change replaced. CopyPixels hands its
  // address to the embedder, which reads through it after the call has
  // returned, so Resize must not free it - see Resize. One buffer, released
  // by the next format change and by the destructor, so the cost is a single
  // extra frame of RGBA for as long as a resolution lasts.
  std::vector<uint8_t> retired_;
  uint32_t width_ = 0;
  uint32_t height_ = 0;
  uint32_t pitch_ = 0;
  uint64_t render_generation_ = 0;
  uint64_t texture_generation_ = 0;
};

}  // namespace vlc_player

#endif  // VLC_PLAYER_NATIVE_VLC_PIXEL_BUFFER_SINK_H_
