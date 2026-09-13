#ifndef VLC_PLAYER_TEST_NATIVE_VLC_PIXEL_BUFFER_SINK_TEST_SUITE_H_
#define VLC_PLAYER_TEST_NATIVE_VLC_PIXEL_BUFFER_SINK_TEST_SUITE_H_

#include <cstddef>
#include <cstdint>
#include <cstring>

#include <gtest/gtest.h>

#include "vlc_pixel_buffer_sink.h"

// The sink is platform-independent C++ with no libVLC dependency, so these
// run anywhere a compiler does - which is the point, because the Windows and
// Linux buffer paths they cover have no CI machine of their own.
namespace vlc_player {
namespace test {

TEST(VlcPixelBufferSink, CopyPixelsRotatesBuffersInsteadOfCopying) {
  VlcPixelBufferSink sink([] {});
  const uint8_t* first = nullptr;
  const uint8_t* second = nullptr;
  const uint8_t* third = nullptr;
  uint32_t width = 0;
  uint32_t height = 0;

  sink.ResizeForTesting(2, 2, 8);

  sink.SimulateFrameForTesting(17);
  ASSERT_TRUE(sink.CopyPixels(&first, &width, &height));
  sink.SimulateFrameForTesting(23);
  ASSERT_TRUE(sink.CopyPixels(&second, &width, &height));
  sink.SimulateFrameForTesting(29);
  ASSERT_TRUE(sink.CopyPixels(&third, &width, &height));

  // A stable address would mean the frame was memcpy'd into a fixed buffer
  // rather than rotated, which is megabytes of traffic every frame.
  EXPECT_NE(first, second);
  EXPECT_NE(second, third);
  EXPECT_NE(first, third);
  EXPECT_EQ(second[0], 23u);
  EXPECT_EQ(third[0], 29u);

  // Rotation must never hand the embedder the buffer libVLC is about to
  // write into - that is the invariant the third buffer exists to keep.
  EXPECT_NE(third, sink.FrameBufferDataForTesting());

  const uint8_t* repeat = nullptr;
  ASSERT_TRUE(sink.CopyPixels(&repeat, &width, &height));
  EXPECT_EQ(repeat, third);
}

// A detach between libVLC's lock and unlock callbacks skips Release. That
// must cost a frame and nothing more: when Acquire held the mutex until
// Release, the skip left it locked forever and the next CopyPixels - on the
// raster thread - hung the window.
TEST(VlcPixelBufferSink, AnAcquireWithNoReleaseDoesNotStrandTheMutex) {
  VlcPixelBufferSink sink([] {});
  sink.ResizeForTesting(4, 4, 16);
  sink.SimulateFrameForTesting(11);

  void* planes[1] = {nullptr};
  ASSERT_NE(sink.Acquire(planes), nullptr);
  // Deliberately no Release, exactly as UnlockCallback does after a Detach.

  const uint8_t* pixels = nullptr;
  uint32_t width = 0;
  uint32_t height = 0;
  EXPECT_TRUE(sink.CopyPixels(&pixels, &width, &height));
  EXPECT_EQ(pixels[0], 11u);

  uint32_t w = 0;
  uint32_t h = 0;
  sink.FrameSize(&w, &h);
  EXPECT_EQ(w, 4u);
}

TEST(VlcPixelBufferSink, ConfigureRequestsRgbaAndSizesTheBuffers) {
  VlcPixelBufferSink sink([] {});
  VlcFrameFormat format;
  std::memcpy(format.chroma, "I420", 5);
  format.width = 4;
  format.height = 3;

  EXPECT_EQ(sink.Configure(&format), 1u);

  EXPECT_STREQ(format.chroma, "RGBA");
  EXPECT_EQ(format.pitches[0], 16u);
  EXPECT_EQ(format.lines[0], 3u);
  EXPECT_EQ(sink.FrameBufferSizeForTesting(), 48u);

  uint32_t width = 0;
  uint32_t height = 0;
  sink.FrameSize(&width, &height);
  EXPECT_EQ(width, 4u);
  EXPECT_EQ(height, 3u);
}

// libVLC's format callback offers the CODED size: a 1080p stream arrives as
// 1920x1088 because the decoder pads the height to a multiple of 16. Taking
// that at face value is wrong whichever converter libVLC then picks. When it
// inserts a scaler the picture is stretched to fill all 1088 rows and is then
// laid out at 1920x1088 - the wrong aspect ratio. When it picks a converter
// that copies planes and ignores the size difference, the padding rows are
// never written and bleed into the bottom edge as a coloured band. Asking for
// the visible picture instead - which the callback's IN/OUT width and height
// exist for - leaves nothing to rescale and no rows to leave unwritten.
TEST(VlcPixelBufferSink,
     ConfigureNegotiatesTheVisiblePictureNotThePaddedBuffer) {
  VlcPixelBufferSink sink([] {}, [](uint32_t* width, uint32_t* height) {
    *width = 1920;
    *height = 1080;
    return true;
  });
  VlcFrameFormat format;
  std::memcpy(format.chroma, "I420", 5);
  format.width = 1920;
  format.height = 1088;

  EXPECT_EQ(sink.Configure(&format), 1u);

  // Written back, so libVLC converts into a buffer that is exactly the
  // picture.
  EXPECT_EQ(format.width, 1920u);
  EXPECT_EQ(format.height, 1080u);
  EXPECT_EQ(format.pitches[0], 7680u);
  EXPECT_EQ(format.lines[0], 1080u);

  uint32_t width = 0;
  uint32_t height = 0;
  sink.FrameSize(&width, &height);
  EXPECT_EQ(width, 1920u);
  EXPECT_EQ(height, 1080u);
  EXPECT_EQ(sink.FrameBufferSizeForTesting(),
            static_cast<size_t>(7680) * 1080);
}

// The probe reads the media's track info; the format callback is negotiating
// with the video output. Nothing keeps those two in step across a media change
// or an adaptive rendition switch, and acting on a stale answer would make
// libVLC rescale the picture into a buffer of the wrong shape - losing
// resolution silently, which is worse than the padding. So only a difference
// that looks like decoder alignment is acted on; everything else leaves the
// offered size exactly where it was.
TEST(VlcPixelBufferSink, ConfigureKeepsTheOfferedSizeWhenTheProbeIsNotPadding) {
  struct Case {
    const char* what;
    bool answered;
    uint32_t visible_width;
    uint32_t visible_height;
  };
  const Case cases[] = {
      {"no track info yet", false, 0, 0},
      {"a different picture entirely", true, 1280, 720},
      {"same height, so nothing to trim", true, 1920, 1088},
      {"taller than the buffer offered", true, 1920, 1200},
      {"a whole macroblock row short - not alignment", true, 1920, 1072},
      {"degenerate", true, 1920, 0},
  };

  for (const Case& test_case : cases) {
    VlcPixelBufferSink sink([] {}, [&test_case](uint32_t* width,
                                                uint32_t* height) {
      *width = test_case.visible_width;
      *height = test_case.visible_height;
      return test_case.answered;
    });
    VlcFrameFormat format;
    std::memcpy(format.chroma, "I420", 5);
    format.width = 1920;
    format.height = 1088;

    EXPECT_EQ(sink.Configure(&format), 1u) << test_case.what;

    EXPECT_EQ(format.width, 1920u) << test_case.what;
    EXPECT_EQ(format.height, 1088u) << test_case.what;
    EXPECT_EQ(format.lines[0], 1088u) << test_case.what;
  }
}

// Every embedder that does not supply a probe - and every existing caller -
// keeps the behaviour it had.
TEST(VlcPixelBufferSink, ConfigureWithoutAProbeUsesTheOfferedSize) {
  VlcPixelBufferSink sink([] {});
  VlcFrameFormat format;
  std::memcpy(format.chroma, "I420", 5);
  format.width = 1920;
  format.height = 1088;

  EXPECT_EQ(sink.Configure(&format), 1u);

  EXPECT_EQ(format.width, 1920u);
  EXPECT_EQ(format.height, 1088u);
}

TEST(VlcPixelBufferSink, CommitNotifiesOnlyForRealPictures) {
  int notifications = 0;
  VlcPixelBufferSink sink([&notifications] { ++notifications; });

  sink.Commit(nullptr);
  EXPECT_EQ(notifications, 0);

  sink.Commit(&sink);
  EXPECT_EQ(notifications, 1);
}

// A mid-session format change - an adaptive ladder stepping 720p up to 1080p,
// or a next episode encoded at another resolution - runs Resize on libVLC's
// thread while the embedder is still reading the pointer the last CopyPixels
// handed out. That read happens after CopyPixels returned and dropped the
// sink's mutex, so no lock can cover it; the block simply has to stay mapped.
// Growing the picture is what makes it a crash rather than a torn frame,
// because that is when the reallocation frees the old block.
TEST(VlcPixelBufferSink, ResizeRetiresTheBufferTheEmbedderIsStillReading) {
  VlcPixelBufferSink sink([] {});
  sink.ResizeForTesting(2, 2, 8);
  sink.SimulateFrameForTesting(17);

  const uint8_t* held = nullptr;
  uint32_t width = 0;
  uint32_t height = 0;
  ASSERT_TRUE(sink.CopyPixels(&held, &width, &height));
  ASSERT_NE(held, nullptr);

  sink.ResizeForTesting(1920, 1080, 1920 * 4);

  // Same address, still ours, still holding the frame the embedder was told
  // to upload. Reading through it must stay defined - under a sanitizer this
  // line is the use-after-free itself.
  EXPECT_EQ(sink.RetiredBufferDataForTesting(), held);
  EXPECT_EQ(sink.RetiredBufferSizeForTesting(), 16u);
  for (size_t index = 0; index < 16; ++index) {
    EXPECT_EQ(held[index], 17u) << "byte " << index;
  }
}

// Retirement is one buffer deep, not a list that grows with every rendition
// change: the block kept alive is always the one from the last format change.
TEST(VlcPixelBufferSink, RetirementKeepsOnlyTheMostRecentBuffer) {
  VlcPixelBufferSink sink([] {});
  sink.ResizeForTesting(2, 2, 8);
  sink.SimulateFrameForTesting(17);

  const uint8_t* held = nullptr;
  uint32_t width = 0;
  uint32_t height = 0;
  ASSERT_TRUE(sink.CopyPixels(&held, &width, &height));

  sink.ResizeForTesting(4, 4, 16);
  ASSERT_EQ(sink.RetiredBufferSizeForTesting(), 16u);

  sink.ResizeForTesting(8, 8, 32);

  EXPECT_EQ(sink.RetiredBufferSizeForTesting(), 64u);
  EXPECT_NE(sink.RetiredBufferDataForTesting(), held);
}

}  // namespace test
}  // namespace vlc_player

#endif  // VLC_PLAYER_TEST_NATIVE_VLC_PIXEL_BUFFER_SINK_TEST_SUITE_H_
