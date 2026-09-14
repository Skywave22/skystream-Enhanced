#ifndef VLC_PLAYER_NATIVE_VLC_VIDEO_OUTPUT_H_
#define VLC_PLAYER_NATIVE_VLC_VIDEO_OUTPUT_H_

#include <cstdint>
#include <mutex>

#include <vlc/vlc.h>

#include "vlc_frame_sink.h"

namespace vlc_player {

// Routes one libvlc_media_player_t's video callbacks into a VlcFrameSink.
//
// Separate from VlcPlayerCore because the two owners of a media player differ:
// Windows and Linux create theirs through the core, while Darwin's belongs to
// VLCKit. Both need the same trampoline boilerplate and teardown ordering.
class VlcVideoOutput {
 public:
  // `player` must outlive this object. `sink` must outlive it too, or Detach
  // must be called first.
  VlcVideoOutput(libvlc_media_player_t* player, VlcFrameSink* sink);
  ~VlcVideoOutput();

  VlcVideoOutput(const VlcVideoOutput&) = delete;
  VlcVideoOutput& operator=(const VlcVideoOutput&) = delete;

  // Stops libVLC calling into the sink, waiting out any callback already
  // running. Idempotent, and the destructor calls it.
  void Detach();

 private:
  // What libVLC's callbacks are actually given, and what makes Detach safe.
  //
  // libVLC 3 captures the callback pointers and their opaque when the video
  // output opens; clearing them on the media player only affects the next one
  // to open. A vout closing on its own thread therefore calls in after Detach
  // has returned, which segfaults if the target has been freed. So the target
  // is never freed: the attachment outlives the VlcVideoOutput, learns under
  // its mutex that the sink is gone, and turns every late callback into a
  // no-op.
  //
  // That is a deliberate leak of a few dozen bytes per media player ever
  // created. Reclaiming it would need a guarantee about vout teardown that
  // libVLC 3 does not offer.
  struct Attachment {
    std::mutex mutex;
    VlcFrameSink* sink = nullptr;
    // The last layout the sink agreed to, kept so a lock the sink cannot
    // answer still has somewhere legal to point libVLC. See ScratchBin.
    uint32_t plane_count = 0;
    uint32_t pitches[kVlcMaxPlanes] = {};
    uint32_t lines[kVlcMaxPlanes] = {};
  };

  // Points `planes` at the shared bin and returns the number filled.
  static void PointAtScratch(const Attachment& attachment, void** planes);

  static unsigned SetupCallback(void** opaque,
                                char* chroma,
                                unsigned* width,
                                unsigned* height,
                                unsigned* pitches,
                                unsigned* lines);
  static void CleanupCallback(void* opaque);
  static void* LockCallback(void* opaque, void** planes);
  static void UnlockCallback(void* opaque, void* picture, void* const* planes);
  static void DisplayCallback(void* opaque, void* picture);

  libvlc_media_player_t* player_;
  Attachment* attachment_;
};

}  // namespace vlc_player

#endif  // VLC_PLAYER_NATIVE_VLC_VIDEO_OUTPUT_H_
