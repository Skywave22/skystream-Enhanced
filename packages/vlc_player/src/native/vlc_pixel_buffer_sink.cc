#include "vlc_pixel_buffer_sink.h"

#include <algorithm>
#include <cstring>
#include <utility>

namespace vlc_player {

VlcPixelBufferSink::VlcPixelBufferSink(
    std::function<void()> on_frame_available)
    : on_frame_available_(std::move(on_frame_available)) {}

VlcPixelBufferSink::~VlcPixelBufferSink() = default;

uint32_t VlcPixelBufferSink::Configure(VlcFrameFormat* format) {
  std::memcpy(format->chroma, "RGBA", 4);
  format->chroma[4] = '\0';
  format->pitches[0] = format->width * 4;
  format->lines[0] = format->height;
  Resize(format->width, format->height, format->pitches[0]);
  return 1;
}

void VlcPixelBufferSink::Cleanup() {}

void* VlcPixelBufferSink::Acquire(void** planes) {
  // The lock is taken and dropped here rather than held until Release.
  //
  // Holding it across the pair made two things possible that must not be.
  // libVLC's vout would block on it whenever the raster thread was inside
  // CopyPixels - the very stall the buffer rotation exists to avoid - and,
  // worse, a Detach between the lock and unlock callbacks skips Release
  // entirely, which left the mutex locked for good and hung the next
  // CopyPixels on the raster thread.
  //
  // Nothing needs it held. frame_buffer_ is only ever written by libVLC and
  // only ever reallocated by Resize, and Resize runs from libVLC's own format
  // callback on that same thread - so its address cannot move underneath a
  // frame in flight. CopyPixels touches only the other two buffers.
  std::lock_guard<std::mutex> lock(mutex_);
  if (frame_buffer_.empty()) {
    planes[0] = nullptr;
    return nullptr;
  }
  planes[0] = frame_buffer_.data();
  return this;
}

void VlcPixelBufferSink::Commit(void* picture) {
  if (picture == nullptr) {
    return;
  }
  if (on_frame_available_) {
    on_frame_available_();
  }
}

void VlcPixelBufferSink::Release(void* picture, void* const* planes) {
  if (picture == nullptr) {
    return;
  }
  // Skipping this - which a Detach between the callbacks now does safely -
  // costs one dropped frame and nothing else.
  std::lock_guard<std::mutex> lock(mutex_);
  std::swap(frame_buffer_, render_buffer_);
  ++render_generation_;
}

bool VlcPixelBufferSink::CopyPixels(const uint8_t** out_buffer,
                                    uint32_t* width,
                                    uint32_t* height) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (render_buffer_.empty()) {
    return false;
  }
  if (texture_generation_ != render_generation_) {
    // A swap, not a copy: a full-frame memcpy here cost megabytes of memory
    // traffic every frame. Acquire no longer holds this mutex across the
    // frame, so the decoder is not waiting on it either.
    //
    // Three buffers is exactly what makes the swap safe. The buffer handed
    // out here becomes render_buffer_, and only the *next* Release rotates it
    // into frame_buffer_ for libVLC to overwrite - a full decode cycle after
    // the embedder finished with it, and the embedder consumes it
    // synchronously before it ever asks for another frame.
    std::swap(texture_buffer_, render_buffer_);
    texture_generation_ = render_generation_;
  }
  *out_buffer = texture_buffer_.data();
  *width = width_;
  *height = height_;
  return true;
}

void VlcPixelBufferSink::FrameSize(uint32_t* width, uint32_t* height) const {
  std::lock_guard<std::mutex> lock(mutex_);
  *width = width_;
  *height = height_;
}

void VlcPixelBufferSink::Resize(uint32_t width,
                                uint32_t height,
                                uint32_t pitch) {
  // Whatever the *previous* format change retired. Freed here, on the way out
  // of the function, so the allocator is never called with the lock held.
  std::vector<uint8_t> released;
  std::lock_guard<std::mutex> lock(mutex_);
  const auto buffer_size = static_cast<size_t>(pitch) * height;
  if (width_ == width && height_ == height && pitch_ == pitch &&
      frame_buffer_.size() == buffer_size) {
    return;
  }
  width_ = width;
  height_ = height;
  pitch_ = pitch;
  frame_buffer_.assign(buffer_size, 0);
  render_buffer_.assign(buffer_size, 0);
  // texture_buffer_ is retired, never reallocated in place.
  //
  // Its address is what CopyPixels hands the embedder, and the embedder reads
  // through that address *after* CopyPixels has returned and dropped this
  // mutex - flutter_windows copies it into a staging texture, the GTK
  // embedder glTexImage2Ds it. Reallocating here freed the block underneath
  // that read: a crash when the picture grows, which is exactly what an
  // adaptive ladder stepping up a rendition does mid-play, and a torn frame
  // when it shrinks. Only the next format change releases it, a whole
  // resolution later.
  //
  // The other two are safe to reallocate in place. frame_buffer_ is written
  // only by libVLC, on the thread that calls Resize; render_buffer_ never
  // leaves this class.
  released = std::move(retired_);
  retired_ = std::move(texture_buffer_);
  texture_buffer_.assign(buffer_size, 0);
  render_generation_ = 0;
  texture_generation_ = 0;
}

#ifdef VLC_PLAYER_TESTING
void VlcPixelBufferSink::ResizeForTesting(uint32_t width,
                                          uint32_t height,
                                          uint32_t pitch) {
  Resize(width, height, pitch);
}

void VlcPixelBufferSink::SimulateFrameForTesting(uint8_t value) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (frame_buffer_.empty()) {
    return;
  }
  std::fill(frame_buffer_.begin(), frame_buffer_.end(), value);
  std::swap(frame_buffer_, render_buffer_);
  ++render_generation_;
}

const uint8_t* VlcPixelBufferSink::FrameBufferDataForTesting() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return frame_buffer_.data();
}

size_t VlcPixelBufferSink::FrameBufferSizeForTesting() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return frame_buffer_.size();
}

const uint8_t* VlcPixelBufferSink::TextureBufferDataForTesting() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return texture_buffer_.data();
}

const uint8_t* VlcPixelBufferSink::RetiredBufferDataForTesting() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return retired_.empty() ? nullptr : retired_.data();
}

size_t VlcPixelBufferSink::RetiredBufferSizeForTesting() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return retired_.size();
}

uint64_t VlcPixelBufferSink::RenderGenerationForTesting() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return render_generation_;
}

uint64_t VlcPixelBufferSink::TextureGenerationForTesting() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return texture_generation_;
}
#endif  // VLC_PLAYER_TESTING

}  // namespace vlc_player
