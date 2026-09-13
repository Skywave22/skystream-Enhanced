#include "vlc_video_output.h"

#include <algorithm>
#include <cstdint>
#include <cstring>

namespace vlc_player {
namespace {

// A bin for pictures nobody will ever look at.
//
// libVLC 3's lock callback cannot refuse a picture: vmem writes back whatever
// the callback leaves in `planes`, so a lock that declines by returning
// nullptr without touching them hands the decoder uninitialised stack
// addresses to memcpy a frame into. Every refusal therefore has to point at
// real memory, and one process-wide buffer is enough - nothing reads it, so
// simultaneous writers cannot bother each other.
//
// It only grows, and a block that has been outgrown is deliberately not
// freed: a video thread may still be writing into it, and the handful of
// bytes that costs is the price of never having to prove otherwise.
// What a refusal gets when the format measures nothing at all. Only has to be
// a real address; see PointAtScratch.
constexpr size_t kEmptyScratchBytes = 4096;

uint8_t* ScratchBin(size_t bytes) {
  static std::mutex mutex;
  static uint8_t* buffer = nullptr;
  static size_t capacity = 0;

  std::lock_guard<std::mutex> lock(mutex);
  if (bytes > capacity) {
    buffer = new uint8_t[bytes]();
    capacity = bytes;
  }
  return buffer;
}

}  // namespace

VlcVideoOutput::VlcVideoOutput(libvlc_media_player_t* player,
                               VlcFrameSink* sink)
    : player_(player), attachment_(new Attachment()) {
  if (player_ == nullptr || sink == nullptr) {
    return;
  }
  attachment_->sink = sink;
  libvlc_video_set_callbacks(player_, &VlcVideoOutput::LockCallback,
                             &VlcVideoOutput::UnlockCallback,
                             &VlcVideoOutput::DisplayCallback, attachment_);
  libvlc_video_set_format_callbacks(player_, &VlcVideoOutput::SetupCallback,
                                    &VlcVideoOutput::CleanupCallback);
}

VlcVideoOutput::~VlcVideoOutput() {
  Detach();
  // attachment_ is deliberately not deleted. See the note on Attachment.
}

void VlcVideoOutput::Detach() {
  {
    std::lock_guard<std::mutex> lock(attachment_->mutex);
    if (attachment_->sink == nullptr) {
      return;
    }
    attachment_->sink = nullptr;
  }
  libvlc_video_set_callbacks(player_, nullptr, nullptr, nullptr, nullptr);
  libvlc_video_set_format_callbacks(player_, nullptr, nullptr);
}

void VlcVideoOutput::PointAtScratch(const Attachment& attachment,
                                    void** planes) {
  size_t total = 0;
  for (uint32_t i = 0; i < attachment.plane_count; ++i) {
    total += static_cast<size_t>(attachment.pitches[i]) * attachment.lines[i];
  }

  // Returning here without touching `planes` would break the one rule this
  // whole function exists to keep: libVLC hands the array in uninitialised and
  // writes the frame into whatever it holds on the way back, so a plane left
  // alone is a decoder writing to a stack address nobody owns. A format that
  // measures nothing should be unreachable - Configure refuses those before
  // libVLC ever locks, and plane_count is only non-zero once one succeeded -
  // but "unreachable" is not something to hand a decoder a pointer to. An
  // empty measurement gets a page of scratch and every plane gets pointed at
  // it; nothing reads the bin, so the overlap costs nothing.
  const bool measured = total != 0;
  if (!measured) {
    total = kEmptyScratchBytes;
  }

  uint8_t* bin = ScratchBin(total);
  const uint32_t used = measured ? attachment.plane_count : kVlcMaxPlanes;
  size_t offset = 0;
  for (uint32_t i = 0; i < used; ++i) {
    planes[i] = bin + offset;
    if (measured) {
      offset += static_cast<size_t>(attachment.pitches[i]) * attachment.lines[i];
    }
  }
}

unsigned VlcVideoOutput::SetupCallback(void** opaque,
                                       char* chroma,
                                       unsigned* width,
                                       unsigned* height,
                                       unsigned* pitches,
                                       unsigned* lines) {
  auto* attachment = static_cast<Attachment*>(*opaque);
  std::lock_guard<std::mutex> lock(attachment->mutex);
  if (attachment->sink == nullptr) {
    return 0;
  }

  VlcFrameFormat format;
  // libVLC passes the source chroma in and expects the answer in the same
  // four bytes; it is not NUL-terminated on the way in.
  std::memcpy(format.chroma, chroma, 4);
  format.chroma[4] = '\0';
  format.width = *width;
  format.height = *height;

  // Configure sizes and allocates the frame buffers, and at 4K RGBA those are
  // tens of megabytes apiece. A std::bad_alloc thrown here would unwind into
  // libVLC's C frames, which have nothing to catch it, and reach
  // std::terminate - the whole app aborting over a format it was free to
  // decline. Returning 0 is that decline, and libVLC already knows how to
  // read it: it tries the next format, or fails the vout cleanly.
  uint32_t planes = 0;
  try {
    planes = attachment->sink->Configure(&format);
  } catch (...) {
    return 0;
  }
  if (planes == 0) {
    return 0;
  }

  std::memcpy(chroma, format.chroma, 4);
  *width = format.width;
  *height = format.height;
  const uint32_t used = std::min<uint32_t>(planes, kVlcMaxPlanes);
  attachment->plane_count = used;
  for (uint32_t i = 0; i < used; ++i) {
    pitches[i] = format.pitches[i];
    lines[i] = format.lines[i];
    attachment->pitches[i] = format.pitches[i];
    attachment->lines[i] = format.lines[i];
  }
  return used;
}

void VlcVideoOutput::CleanupCallback(void* opaque) {
  auto* attachment = static_cast<Attachment*>(opaque);
  std::lock_guard<std::mutex> lock(attachment->mutex);
  if (attachment->sink != nullptr) {
    attachment->sink->Cleanup();
  }
}

void* VlcVideoOutput::LockCallback(void* opaque, void** planes) {
  auto* attachment = static_cast<Attachment*>(opaque);
  std::lock_guard<std::mutex> lock(attachment->mutex);
  void* picture =
      attachment->sink == nullptr ? nullptr : attachment->sink->Acquire(planes);
  if (picture == nullptr) {
    // Detached, or the sink had no buffer to spare. Either way libVLC is
    // about to write a frame, so it needs somewhere to write it.
    PointAtScratch(*attachment, planes);
  }
  return picture;
}

void VlcVideoOutput::UnlockCallback(void* opaque,
                                    void* picture,
                                    void* const* planes) {
  auto* attachment = static_cast<Attachment*>(opaque);
  std::lock_guard<std::mutex> lock(attachment->mutex);
  if (attachment->sink != nullptr) {
    attachment->sink->Release(picture, planes);
  }
}

void VlcVideoOutput::DisplayCallback(void* opaque, void* picture) {
  auto* attachment = static_cast<Attachment*>(opaque);
  std::lock_guard<std::mutex> lock(attachment->mutex);
  if (attachment->sink != nullptr) {
    attachment->sink->Commit(picture);
  }
}

}  // namespace vlc_player
