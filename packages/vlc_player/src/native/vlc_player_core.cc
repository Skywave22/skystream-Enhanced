#include "vlc_player_core.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <fstream>
#include <sstream>
#include <thread>
#include <utility>

namespace vlc_player {
namespace {

int64_t NonNegative(libvlc_time_t value) {
  return std::max<int64_t>(0, value);
}

// FNV-1a, 64 bit. Not a security hash - it only has to make two different
// track lists land on two different numbers often enough that a snapshot
// diff notices, and it has to cost nothing at the 500 ms poll rate.
constexpr uint64_t kFnvOffsetBasis = 14695981039346656037ULL;
constexpr uint64_t kFnvPrime = 1099511628211ULL;

uint64_t FoldByte(uint64_t hash, uint8_t byte) {
  return (hash ^ byte) * kFnvPrime;
}

uint64_t FoldBytes(uint64_t hash, const void* data, size_t size) {
  const auto* bytes = static_cast<const uint8_t*>(data);
  for (size_t index = 0; index < size; ++index) {
    hash = FoldByte(hash, bytes[index]);
  }
  return hash;
}

uint64_t FoldTrackList(uint64_t hash,
                       const std::vector<VlcTrackDescription>& tracks) {
  // A list separator, so an id that moves from the audio list to the spu list
  // cannot leave the fingerprint where it was.
  hash = FoldByte(hash, 0x1f);
  for (const auto& track : tracks) {
    const int32_t id = static_cast<int32_t>(track.id);
    hash = FoldBytes(hash, &id, sizeof(id));
    hash = FoldBytes(hash, track.name.data(), track.name.size());
    // A record separator, so ("a", "bc") and ("ab", "c") differ.
    hash = FoldByte(hash, 0x1e);
  }
  return hash;
}

std::atomic<uint64_t> g_snapshot_counter{0};

std::string EnvironmentValue(const char* name) {
#ifdef _WIN32
  char* value = nullptr;
  size_t size = 0;
  if (_dupenv_s(&value, &size, name) != 0 || value == nullptr) {
    return "";
  }
  std::string result(value);
  std::free(value);
  return result;
#else
  const char* value = std::getenv(name);
  return value == nullptr ? "" : value;
#endif
}

std::string TemporarySnapshotPath() {
#ifdef _WIN32
  const char* env_names[] = {"TEMP", "TMP"};
  const char separator = '\\';
  std::string directory = ".";
#else
  const char* env_names[] = {"TMPDIR", "TEMP", "TMP"};
  const char separator = '/';
  std::string directory = "/tmp";
#endif
  for (const char* name : env_names) {
    const std::string value = EnvironmentValue(name);
    if (!value.empty()) {
      directory = value;
      break;
    }
  }
  if (!directory.empty() && directory.back() != '/' &&
      directory.back() != '\\') {
    directory.push_back(separator);
  }

  const auto timestamp =
      std::chrono::duration_cast<std::chrono::microseconds>(
          std::chrono::system_clock::now().time_since_epoch())
          .count();
  const uint64_t counter = g_snapshot_counter.fetch_add(1);
  std::ostringstream path;
  path << directory << "vlc_player_snapshot_" << timestamp << "_" << counter
       << ".png";
  return path.str();
}

bool ReadFileIfReady(const std::string& path, std::vector<uint8_t>* data) {
  std::ifstream file(path, std::ios::binary | std::ios::ate);
  if (!file) {
    return false;
  }
  const std::ifstream::pos_type size = file.tellg();
  if (size <= 0) {
    return false;
  }
  const auto byte_count = static_cast<std::streamsize>(size);
  data->resize(static_cast<size_t>(byte_count));
  file.seekg(0, std::ios::beg);
  file.read(reinterpret_cast<char*>(data->data()), byte_count);
  return file.good();
}

}  // namespace

VlcPlayerCore::VlcPlayerCore(std::vector<std::string> options,
                             FrameAvailableCallback on_frame_available)
    : on_frame_available_(std::move(on_frame_available)) {
  std::vector<const char*> argv;
  argv.reserve(options.size());
  for (const auto& option : options) {
    argv.push_back(option.c_str());
  }

  try {
    instance_ =
        std::make_unique<VLC::Instance>(static_cast<int>(argv.size()),
                                        argv.data());
    player_ = std::make_unique<VLC::MediaPlayer>(*instance_);
  } catch (const std::exception& error) {
    init_error_ = error.what();
    return;
  }

  frame_sink_ = std::make_unique<VlcPixelBufferSink>(
      [this] {
        if (!disposed_.load() && on_frame_available_) {
          on_frame_available_();
        }
      },
      // The visible picture size, for the sink's format negotiation. Reads
      // the media's video track as the demuxer declared it -
      // libvlc_video_get_size touches the track info, not the video output -
      // which is the same number the Darwin renderer publishes alongside its
      // coded size.
      //
      // Called on libVLC's video output thread, from inside the format
      // callback. player_ is safe to touch there: Dispose detaches the video
      // output first, and Detach takes the attachment lock that the format
      // callback is holding, so no callback can still be running by the time
      // player_ is reset.
      [this](uint32_t* width, uint32_t* height) {
        unsigned visible_width = 0;
        unsigned visible_height = 0;
        if (player_ == nullptr ||
            !player_->size(0, &visible_width, &visible_height)) {
          return false;
        }
        *width = visible_width;
        *height = visible_height;
        return true;
      });
  video_output_ =
      std::make_unique<VlcVideoOutput>(player_->get(), frame_sink_.get());
}

VlcPlayerCore::~VlcPlayerCore() {
  Dispose();
}

bool VlcPlayerCore::is_valid() const {
  return init_error_.empty() && player_ != nullptr;
}

const std::string& VlcPlayerCore::error() const {
  return init_error_;
}

std::string VlcPlayerCore::SetSource(const std::string& uri,
                                     const std::vector<std::string>& headers,
                                     const std::vector<std::string>&
                                         media_options,
                                     int64_t start_position,
                                     bool auto_play) {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  if (uri.empty()) {
    return "A non-empty uri is required.";
  }

  try {
    VLC::Media media(*instance_, uri, VLC::Media::FromLocation);
    for (const auto& header : headers) {
      media.addOption(header);
    }
    for (const auto& option : media_options) {
      media.addOption(option);
    }
    if (start_position > 0) {
      std::ostringstream option;
      option << ":start-time=" << (static_cast<double>(start_position) / 1000);
      media.addOption(option.str());
    }
    player_->setMedia(media);
  } catch (const std::exception&) {
    return "Unable to create VLC media.";
  }

  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    state_override_ = "opening";
    error_code_.clear();
    error_description_.clear();
  }

  return auto_play ? Play() : "";
}

std::string VlcPlayerCore::Play() {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  if (!player_->play()) {
    return "VLC failed to start playback.";
  }
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    state_override_.clear();
  }
  return "";
}

std::string VlcPlayerCore::Pause() {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  player_->pause();
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    state_override_.clear();
  }
  return "";
}

std::string VlcPlayerCore::Stop() {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  player_->stop();
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    state_override_ = "stopped";
  }
  return "";
}

std::string VlcPlayerCore::SeekTo(int64_t milliseconds) {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  player_->setTime(std::max<int64_t>(0, milliseconds));
  return "";
}

std::string VlcPlayerCore::SetVolume(int volume) {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  const int normalized_volume = std::clamp(volume, 0, 200);
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    volume_ = normalized_volume;
  }
  player_->setVolume(normalized_volume);
  return "";
}

std::string VlcPlayerCore::SetPlaybackSpeed(double speed) {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  if (!std::isfinite(speed) || speed <= 0) {
    return "A finite positive playback speed is required.";
  }
  player_->setRate(static_cast<float>(speed));
  return "";
}

std::string VlcPlayerCore::SetAudioDelay(int64_t microseconds) {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  if (!player_->setAudioDelay(microseconds)) {
    return "VLC failed to set audio delay.";
  }
  return "";
}

std::string VlcPlayerCore::SetSubtitleDelay(int64_t microseconds) {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  if (player_->setSpuDelay(microseconds) != 0) {
    return "VLC failed to set subtitle delay.";
  }
  return "";
}

std::vector<uint8_t> VlcPlayerCore::TakeSnapshot(uint32_t width,
                                                 uint32_t height,
                                                 std::string* error) {
  if (error != nullptr) {
    error->clear();
  }
  const auto active_error = ActiveError();
  if (!active_error.empty()) {
    if (error != nullptr) {
      *error = active_error;
    }
    return {};
  }

  auto media = player_->media();
  if (media == nullptr) {
    if (error != nullptr) {
      *error = "No media is loaded.";
    }
    return {};
  }

  const std::string path = TemporarySnapshotPath();
  if (!player_->takeSnapshot(0, path, width, height)) {
    std::remove(path.c_str());
    if (error != nullptr) {
      *error = "VLC failed to take a snapshot.";
    }
    return {};
  }

  for (int attempt = 0; attempt < 40; ++attempt) {
    std::vector<uint8_t> data;
    if (ReadFileIfReady(path, &data)) {
      std::remove(path.c_str());
      return data;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }

  std::remove(path.c_str());
  if (error != nullptr) {
    *error = "VLC did not produce snapshot image data.";
  }
  return {};
}

std::vector<VlcTrackDescription> VlcPlayerCore::GetAudioTracks() {
  if (!is_valid()) {
    return {};
  }
  return TrackDescriptions(player_->audioTrackDescription());
}

std::string VlcPlayerCore::SetAudioTrack(int id) {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  if (!player_->setAudioTrack(id)) {
    return "Audio track " + std::to_string(id) + " was not found.";
  }
  return "";
}

std::vector<VlcTrackDescription> VlcPlayerCore::GetSubtitleTracks() {
  if (!is_valid()) {
    return {};
  }
  return TrackDescriptions(player_->spuDescription());
}

std::string VlcPlayerCore::SetSubtitleTrack(int id) {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  if (player_->setSpu(id) != 0) {
    return "Subtitle track " + std::to_string(id) + " was not found.";
  }
  return "";
}

std::string VlcPlayerCore::DisableSubtitle() {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  player_->setSpu(-1);
  return "";
}

std::string VlcPlayerCore::AddSubtitle(const std::string& uri) {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  if (uri.empty()) {
    return "A non-empty subtitle uri is required.";
  }
  if (!player_->addSlave(VLC::MediaSlave::Type::Subtitle, uri, true)) {
    return "Failed to add subtitle: " + uri;
  }
  return "";
}

VlcMediaInfo VlcPlayerCore::GetMediaInfo() {
  VlcMediaInfo info;
  if (!is_valid()) {
    return info;
  }

  info.duration = NonNegative(player_->length());
  auto media = player_->media();
  if (media == nullptr) {
    return info;
  }

  info.title = media->meta(libvlc_meta_Title);
  info.artist = media->meta(libvlc_meta_Artist);
  info.album = media->meta(libvlc_meta_Album);

  for (const auto& track : media->tracks()) {
    auto track_info = MediaTrackInfo(track);
    switch (track.type()) {
      case VLC::MediaTrack::Type::Audio:
        info.audio_tracks.push_back(std::move(track_info));
        break;
      case VLC::MediaTrack::Type::Video:
        info.video_tracks.push_back(std::move(track_info));
        break;
      case VLC::MediaTrack::Type::Subtitle:
        info.subtitle_tracks.push_back(std::move(track_info));
        break;
      default:
        break;
    }
  }
  return info;
}

VlcMediaStats VlcPlayerCore::GetMediaStats() {
  VlcMediaStats result;
  if (!is_valid()) {
    return result;
  }

  auto media = player_->media();
  if (media == nullptr) {
    return result;
  }

  libvlc_media_stats_t stats{};
  if (!media->stats(&stats)) {
    return result;
  }

  result.available = true;
  result.read_bytes = stats.i_read_bytes;
  result.input_bitrate = stats.f_input_bitrate;
  result.demux_read_bytes = stats.i_demux_read_bytes;
  result.demux_bitrate = stats.f_demux_bitrate;
  result.demux_corrupted = stats.i_demux_corrupted;
  result.demux_discontinuity = stats.i_demux_discontinuity;
  result.decoded_video = stats.i_decoded_video;
  result.decoded_audio = stats.i_decoded_audio;
  result.displayed_pictures = stats.i_displayed_pictures;
  result.lost_pictures = stats.i_lost_pictures;
  result.played_audio_buffers = stats.i_played_abuffers;
  result.lost_audio_buffers = stats.i_lost_abuffers;
  result.sent_packets = stats.i_sent_packets;
  result.sent_bytes = stats.i_sent_bytes;
  result.send_bitrate = stats.f_send_bitrate;
  return result;
}

VlcSnapshot VlcPlayerCore::Snapshot() {
  VlcSnapshot snapshot;
  if (!is_valid()) {
    std::lock_guard<std::mutex> lock(state_mutex_);
    snapshot.volume = volume_;
    if (!error_description_.empty()) {
      snapshot.error_code =
          error_code_.empty() ? "create_failed" : error_code_;
    }
    snapshot.error_description = error_description_;
    return snapshot;
  }

  auto media = player_->media();
  if (media == nullptr) {
    std::lock_guard<std::mutex> lock(state_mutex_);
    snapshot.state = state_override_.empty() ? "idle" : state_override_;
    snapshot.volume = volume_;
    snapshot.error_code = error_code_;
    snapshot.error_description = error_description_;
    return snapshot;
  }

  const libvlc_state_t state = player_->state();
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    if (state == libvlc_Error) {
      error_code_ = "playback_error";
      error_description_ = "VLC encountered an error while playing the media.";
    }
    snapshot.state = state_override_.empty() ? StateName(state) : state_override_;
    snapshot.volume = volume_;
    snapshot.error_code = error_code_;
    snapshot.error_description = error_description_;
  }
  snapshot.position = NonNegative(player_->time());
  snapshot.duration = NonNegative(player_->length());
  snapshot.playback_speed = static_cast<double>(player_->rate());
  snapshot.audio_delay = player_->audioDelay();
  snapshot.subtitle_delay = player_->spuDelay();
  snapshot.audio_track = player_->audioTrack();
  snapshot.subtitle_track = player_->spu();
  {
    // No ES event is registered on this core; the poller and the forced
    // post-mutation snapshots diff the track SET instead. A count cannot see
    // a same-size swap - an adaptive rendition change or an MPEG-TS PMT
    // update replaces the audio/spu ES without changing how many there are -
    // and a consumer that never refetches is left drawing the old names with
    // nothing ticked, because the active id it is matching no longer exists.
    const int64_t fingerprint =
        TrackSetFingerprint(GetAudioTracks(), GetSubtitleTracks());
    std::lock_guard<std::mutex> lock(state_mutex_);
    if (fingerprint != last_track_fingerprint_) {
      last_track_fingerprint_ = fingerprint;
      ++track_revision_;
    }
    snapshot.track_revision = track_revision_;
  }
  snapshot.is_ready = IsReadyState(snapshot.state);
  snapshot.is_seekable = player_->isSeekable();
  snapshot.is_live = IsLiveState(snapshot.state) && snapshot.duration == 0 &&
                     !snapshot.is_seekable;
  // The texture's own size, which is the only size Flutter can lay it out at.
  // It is the visible picture whenever the sink managed to negotiate that -
  // see VlcPixelBufferSink::Configure - and the coded buffer when it did not,
  // which is what it always was before. No separate coded size is published
  // because on this path there is nothing for a consumer to clip: the buffer
  // and the picture are the same rectangle.
  uint32_t frame_width = 0;
  uint32_t frame_height = 0;
  frame_sink_->FrameSize(&frame_width, &frame_height);
  snapshot.video_width = frame_width;
  snapshot.video_height = frame_height;
  return snapshot;
}

bool VlcPlayerCore::CopyPixels(const uint8_t** out_buffer,
                               uint32_t* width,
                               uint32_t* height) {
  if (frame_sink_ == nullptr) {
    return false;
  }
  return frame_sink_->CopyPixels(out_buffer, width, height);
}

void VlcPlayerCore::Dispose() {
  if (disposed_.exchange(true)) {
    return;
  }
  if (video_output_ != nullptr) {
    video_output_->Detach();
  }
  if (player_ != nullptr) {
    player_->stop();
    player_.reset();
  }
  video_output_.reset();
  on_frame_available_ = nullptr;
  instance_.reset();
}

#ifdef VLC_PLAYER_TESTING
VlcPixelBufferSink* VlcPlayerCore::FrameSinkForTesting() {
  return frame_sink_.get();
}

void VlcPlayerCore::ResizeVideoBufferForTesting(uint32_t width,
                                                uint32_t height,
                                                uint32_t pitch) {
  frame_sink_->ResizeForTesting(width, height, pitch);
}

void VlcPlayerCore::SimulateFrameForTesting(uint8_t value) {
  frame_sink_->SimulateFrameForTesting(value);
}

const uint8_t* VlcPlayerCore::FrameBufferDataForTesting() const {
  return frame_sink_->FrameBufferDataForTesting();
}

size_t VlcPlayerCore::FrameBufferSizeForTesting() const {
  return frame_sink_->FrameBufferSizeForTesting();
}

uint64_t VlcPlayerCore::RenderGenerationForTesting() const {
  return frame_sink_->RenderGenerationForTesting();
}

uint64_t VlcPlayerCore::TextureGenerationForTesting() const {
  return frame_sink_->TextureGenerationForTesting();
}
#endif  // VLC_PLAYER_TESTING

std::string VlcPlayerCore::ActiveError() const {
  if (disposed_.load()) {
    return "The vlc_player has been disposed.";
  }
  if (!init_error_.empty()) {
    return init_error_;
  }
  if (player_ == nullptr) {
    return "The VLC media player is not available.";
  }
  return "";
}

std::string VlcPlayerCore::StateName(libvlc_state_t state) {
  switch (state) {
    case libvlc_Opening:
      return "opening";
    case libvlc_Buffering:
      return "buffering";
    case libvlc_Playing:
      return "playing";
    case libvlc_Paused:
      return "paused";
    case libvlc_Stopped:
      return "stopped";
    case libvlc_Ended:
      return "ended";
    case libvlc_Error:
      return "error";
    default:
      return "idle";
  }
}

bool VlcPlayerCore::IsReadyState(const std::string& state) {
  return state == "playing" || state == "paused" || state == "stopped" ||
         state == "ended";
}

bool VlcPlayerCore::IsLiveState(const std::string& state) {
  return state == "buffering" || state == "playing" || state == "paused";
}

std::string VlcPlayerCore::FourCCString(uint32_t value) {
  char codec[5] = {
      static_cast<char>(value & 0xff),
      static_cast<char>((value >> 8) & 0xff),
      static_cast<char>((value >> 16) & 0xff),
      static_cast<char>((value >> 24) & 0xff),
      '\0',
  };
  for (int i = 0; i < 4; ++i) {
    if (codec[i] < 32 || codec[i] > 126) {
      return "";
    }
  }
  return codec;
}

std::string VlcPlayerCore::TrackTypeName(VLC::MediaTrack::Type type) {
  switch (type) {
    case VLC::MediaTrack::Type::Audio:
      return "audio";
    case VLC::MediaTrack::Type::Video:
      return "video";
    case VLC::MediaTrack::Type::Subtitle:
      return "subtitle";
    default:
      return "unknown";
  }
}

VlcMediaTrackInfo VlcPlayerCore::MediaTrackInfo(const VLC::MediaTrack& track) {
  VlcMediaTrackInfo info;
  info.type = TrackTypeName(track.type());
  info.codec = FourCCString(track.codec());
  info.language = track.language();
  info.bitrate = track.bitrate();
  if (track.type() == VLC::MediaTrack::Type::Video) {
    info.width = track.width();
    info.height = track.height();
  }
  if (track.type() == VLC::MediaTrack::Type::Audio) {
    info.channels = track.channels();
    info.sample_rate = track.rate();
  }
  return info;
}

int64_t VlcPlayerCore::TrackSetFingerprint(
    const std::vector<VlcTrackDescription>& audio,
    const std::vector<VlcTrackDescription>& subtitles) {
  uint64_t hash = kFnvOffsetBasis;
  hash = FoldTrackList(hash, audio);
  hash = FoldTrackList(hash, subtitles);
  // Masked to stay non-negative so -1 remains an unreachable "nothing seen
  // yet" sentinel for last_track_fingerprint_.
  return static_cast<int64_t>(hash & 0x7fffffffffffffffULL);
}

std::vector<VlcTrackDescription> VlcPlayerCore::TrackDescriptions(
    const std::vector<VLC::TrackDescription>& tracks) {
  std::vector<VlcTrackDescription> result;
  result.reserve(tracks.size());
  for (const auto& track : tracks) {
    result.push_back(VlcTrackDescription{
        track.id(),
        track.name(),
        "",
    });
  }
  return result;
}

}  // namespace vlc_player
