#include "LumenCore.h"
#include "LumenCoreInternal.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

namespace {
  constexpr std::size_t default_frame_capacity = 4;
  constexpr std::size_t default_event_capacity = 32;
  constexpr std::string_view encoded_capture_queue_overflow_message = "core-forwarder-overflow";

  LumenCoreEncodedCaptureTileMetadata single_frame_tile_metadata() {
    LumenCoreEncodedCaptureTileMetadata metadata {};
    metadata.tile_count = 1;
    metadata.encoded_lane_count = 1;
    return metadata;
  }

  LumenCoreEncodedCaptureTileMetadata normalized_tile_metadata(
    LumenCoreEncodedCaptureTileMetadata metadata
  ) {
    metadata.tile_count = std::max<std::uint32_t>(1, metadata.tile_count);
    metadata.encoded_lane_count = std::max<std::uint32_t>(1, metadata.encoded_lane_count);
    if (!metadata.has_tile_region) {
      metadata.tile_origin_x = 0;
      metadata.tile_origin_y = 0;
      metadata.tile_width = 0;
      metadata.tile_height = 0;
    }
    return metadata;
  }

  struct retained_sample_buffer_t {
    CMSampleBufferRef value = nullptr;

    retained_sample_buffer_t() = default;

    explicit retained_sample_buffer_t(CMSampleBufferRef sample_buffer) :
        value(sample_buffer ? reinterpret_cast<CMSampleBufferRef>(const_cast<void *>(CFRetain(sample_buffer))) : nullptr) {
    }

    retained_sample_buffer_t(const retained_sample_buffer_t &other) :
        value(other.value ? reinterpret_cast<CMSampleBufferRef>(const_cast<void *>(CFRetain(other.value))) : nullptr) {
    }

    retained_sample_buffer_t &operator=(const retained_sample_buffer_t &other) {
      if (this == &other) {
        return *this;
      }

      reset();
      value = other.value ? reinterpret_cast<CMSampleBufferRef>(const_cast<void *>(CFRetain(other.value))) : nullptr;
      return *this;
    }

    retained_sample_buffer_t(retained_sample_buffer_t &&other) noexcept :
        value(std::exchange(other.value, nullptr)) {
    }

    retained_sample_buffer_t &operator=(retained_sample_buffer_t &&other) noexcept {
      if (this == &other) {
        return *this;
      }

      reset();
      value = std::exchange(other.value, nullptr);
      return *this;
    }

    ~retained_sample_buffer_t() {
      reset();
    }

    void reset() {
      if (value) {
        CFRelease(value);
        value = nullptr;
      }
    }
  };

  struct encoded_event_state_t {
    LumenCoreCaptureEventKind kind = LumenCoreCaptureEventKindUnknown;
    std::string message;
    bool has_stop_status = false;
    std::int32_t stop_status = 0;
    bool has_automatic_restart_count = false;
    std::uint64_t automatic_restart_count = 0;
    bool has_source_display_time = false;
    std::uint64_t source_display_time = 0;

    LumenCoreEncodedCaptureEventRecord record() const {
      LumenCoreEncodedCaptureEventRecord record {};
      record.has_value = true;
      record.kind = kind;
      record.has_stop_status = has_stop_status;
      record.stop_status = stop_status;
      record.has_automatic_restart_count = has_automatic_restart_count;
      record.automatic_restart_count = automatic_restart_count;
      record.has_source_display_time = has_source_display_time;
      record.source_display_time = source_display_time;
      return record;
    }
  };

  struct encoded_frame_state_t {
    LumenCoreCaptureCodec codec = LumenCoreCaptureCodecUnknown;
    std::shared_ptr<retained_sample_buffer_t> sample_buffer;
    std::uint64_t source_sequence_number = 0;
    std::uint64_t source_display_time = 0;
    bool has_output_callback_latency_milliseconds = false;
    double output_callback_latency_milliseconds = 0.0;
    bool is_key_frame = false;
    bool is_hdr_signaled = false;
    bool is_replay = false;
    LumenCoreEncodedCaptureTileMetadata tile_metadata = single_frame_tile_metadata();

    std::size_t payload_size() const {
      if (!sample_buffer || !sample_buffer->value) {
        return 0;
      }

      CMBlockBufferRef block_buffer = CMSampleBufferGetDataBuffer(sample_buffer->value);
      if (!block_buffer) {
        return 0;
      }

      return static_cast<std::size_t>(CMBlockBufferGetDataLength(block_buffer));
    }

    LumenCoreEncodedCaptureFrameRecord record() const {
      LumenCoreEncodedCaptureFrameRecord record {};
      record.has_value = true;
      record.codec = codec;
      record.payload_size = payload_size();
      record.source_sequence_number = source_sequence_number;
      record.source_display_time = source_display_time;
      record.has_output_callback_latency_milliseconds = has_output_callback_latency_milliseconds;
      record.output_callback_latency_milliseconds = output_callback_latency_milliseconds;
      record.is_key_frame = is_key_frame;
      record.is_hdr_signaled = is_hdr_signaled;
      record.is_replay = is_replay;
      record.tile_metadata = tile_metadata;
      return record;
    }
  };

  struct audio_event_state_t {
    LumenCoreCaptureEventKind kind = LumenCoreCaptureEventKindUnknown;
    std::string message;
    bool has_stop_status = false;
    std::int32_t stop_status = 0;
    bool has_automatic_restart_count = false;
    std::uint64_t automatic_restart_count = 0;
    bool has_source_sequence_number = false;
    std::uint64_t source_sequence_number = 0;

    LumenCoreAudioCaptureEventRecord record() const {
      LumenCoreAudioCaptureEventRecord record {};
      record.has_value = true;
      record.kind = kind;
      record.has_stop_status = has_stop_status;
      record.stop_status = stop_status;
      record.has_automatic_restart_count = has_automatic_restart_count;
      record.automatic_restart_count = automatic_restart_count;
      record.has_source_sequence_number = has_source_sequence_number;
      record.source_sequence_number = source_sequence_number;
      return record;
    }
  };

  struct audio_frame_state_t {
    std::vector<std::uint8_t> pcm_float32le;
    std::uint64_t sequence_number = 0;
    std::uint64_t host_time_nanoseconds = 0;
    std::int32_t sample_rate = 0;
    std::int32_t channel_count = 0;
    std::int32_t frame_count = 0;

    LumenCoreAudioCaptureFrameRecord record() const {
      LumenCoreAudioCaptureFrameRecord record {};
      record.has_value = true;
      record.sequence_number = sequence_number;
      record.host_time_nanoseconds = host_time_nanoseconds;
      record.sample_rate = sample_rate;
      record.channel_count = channel_count;
      record.frame_count = frame_count;
      record.pcm_byte_count = pcm_float32le.size();
      return record;
    }
  };

  template<typename FrameQueue, typename EventQueue>
  bool ingress_has_pending(const FrameQueue &frames, const EventQueue &events) {
    return !frames.empty() || !events.empty();
  }
}

struct LumenCoreEncodedCaptureIngress {
  mutable std::mutex mutex;
  std::condition_variable data_cv;
  bool producer_active = false;
  std::uint64_t frame_count = 0;
  std::uint64_t event_count = 0;
  std::uint64_t dropped_frame_count = 0;
  std::uint64_t dropped_event_count = 0;
  std::size_t frame_capacity = default_frame_capacity;
  std::size_t event_capacity = default_event_capacity;
  std::optional<encoded_frame_state_t> last_frame;
  std::optional<encoded_event_state_t> last_event;
  std::deque<encoded_frame_state_t> pending_frames;
  std::deque<encoded_event_state_t> pending_events;
};

namespace {
  void push_encoded_capture_drop_event_locked(
    LumenCoreEncodedCaptureIngress *ingress,
    std::uint64_t source_display_time
  ) {
    encoded_event_state_t event {};
    event.kind = LumenCoreCaptureEventKindDroppedFrame;
    event.message = encoded_capture_queue_overflow_message;
    event.has_source_display_time = true;
    event.source_display_time = source_display_time;

    ingress->event_count += 1;
    ingress->last_event = event;
    ingress->pending_events.push_back(std::move(event));
    while (ingress->pending_events.size() > ingress->event_capacity) {
      ingress->pending_events.pop_front();
      ingress->dropped_event_count += 1;
    }
  }
}

struct LumenCoreAudioCaptureIngress {
  mutable std::mutex mutex;
  std::condition_variable data_cv;
  bool producer_active = false;
  std::uint64_t frame_count = 0;
  std::uint64_t event_count = 0;
  std::uint64_t dropped_frame_count = 0;
  std::uint64_t dropped_event_count = 0;
  std::size_t frame_capacity = default_frame_capacity;
  std::size_t event_capacity = default_event_capacity;
  std::optional<audio_frame_state_t> last_frame;
  std::optional<audio_event_state_t> last_event;
  std::deque<audio_frame_state_t> pending_frames;
  std::deque<audio_event_state_t> pending_events;
};

struct LumenCoreCaptureRequestState {
  mutable std::mutex mutex;
  std::condition_variable change_cv;
  LumenCoreCaptureRequestSnapshot snapshot {};

  LumenCoreCaptureRequestState() {
    snapshot.codec = LumenCoreCaptureCodecUnknown;
    snapshot.audio_source_kind = LumenCoreAudioCaptureSourceKindUnknown;
    snapshot.preprocess_strategy = LumenCoreCapturePreprocessStrategyNone;
    snapshot.queue_profile = LumenCoreCaptureQueueProfileAuto;
  }
};

namespace lumen::core {
  std::string version_string() {
    return "LumenCore bootstrap";
  }

  std::string runtime_description() {
    return "C and C++ compatibility surface for the Swift/Tuist Lumen shell.";
  }

  encoded_capture_ingress::encoded_capture_ingress() :
      handle_(LumenCoreEncodedCaptureIngressCreate()) {
  }

  encoded_capture_ingress::~encoded_capture_ingress() {
    LumenCoreEncodedCaptureIngressDestroy(handle_);
    handle_ = nullptr;
  }

  encoded_capture_ingress::encoded_capture_ingress(encoded_capture_ingress &&other) noexcept :
      handle_(std::exchange(other.handle_, nullptr)) {
  }

  encoded_capture_ingress &encoded_capture_ingress::operator=(encoded_capture_ingress &&other) noexcept {
    if (this == &other) {
      return *this;
    }

    LumenCoreEncodedCaptureIngressDestroy(handle_);
    handle_ = std::exchange(other.handle_, nullptr);
    return *this;
  }

  void encoded_capture_ingress::reset() {
    LumenCoreEncodedCaptureIngressReset(handle_);
  }

  void encoded_capture_ingress::set_frame_capacity(std::size_t capacity) {
    LumenCoreEncodedCaptureIngressSetFrameCapacity(handle_, capacity);
  }

  void encoded_capture_ingress::set_event_capacity(std::size_t capacity) {
    LumenCoreEncodedCaptureIngressSetEventCapacity(handle_, capacity);
  }

  void encoded_capture_ingress::consume_sample_buffer(
    LumenCoreCaptureCodec codec,
    std::uint64_t source_sequence_number,
    std::uint64_t source_display_time,
    bool has_output_callback_latency_milliseconds,
    double output_callback_latency_milliseconds,
    bool is_key_frame,
    bool is_hdr_signaled,
    bool is_replay,
    CMSampleBufferRef sample_buffer
  ) {
    LumenCoreEncodedCaptureIngressConsumeSampleBuffer(
      handle_,
      codec,
      source_sequence_number,
      source_display_time,
      has_output_callback_latency_milliseconds,
      output_callback_latency_milliseconds,
      is_key_frame,
      is_hdr_signaled,
      is_replay,
      sample_buffer
    );
  }

  void encoded_capture_ingress::consume_event(
    LumenCoreCaptureEventKind kind,
    const char *message,
    bool has_stop_status,
    std::int32_t stop_status,
    bool has_automatic_restart_count,
    std::uint64_t automatic_restart_count,
    bool has_source_display_time,
    std::uint64_t source_display_time
  ) {
    LumenCoreEncodedCaptureIngressConsumeEvent(
      handle_,
      kind,
      message,
      has_stop_status,
      stop_status,
      has_automatic_restart_count,
      automatic_restart_count,
      has_source_display_time,
      source_display_time
    );
  }

  LumenCoreEncodedCaptureIngressSnapshot encoded_capture_ingress::snapshot() const {
    return LumenCoreEncodedCaptureIngressCopySnapshot(handle_);
  }

  CMSampleBufferRef encoded_capture_ingress::create_retained_last_sample_buffer() const {
    return LumenCoreEncodedCaptureIngressCreateRetainedLastSampleBuffer(handle_);
  }

  LumenCoreEncodedCaptureFrameRecord encoded_capture_ingress::pop_next_frame(
    CMSampleBufferRef *sample_buffer_out
  ) {
    return LumenCoreEncodedCaptureIngressPopNextFrame(handle_, sample_buffer_out);
  }

  LumenCoreEncodedCaptureEventRecord encoded_capture_ingress::pop_next_event(
    char *message_destination,
    std::size_t message_capacity
  ) {
    return LumenCoreEncodedCaptureIngressPopNextEvent(handle_, message_destination, message_capacity);
  }

  std::string encoded_capture_ingress::copy_last_event_message() const {
    std::array<char, 512> buffer {};
    const auto copied = LumenCoreEncodedCaptureIngressCopyLastEventMessage(
      handle_,
      buffer.data(),
      buffer.size()
    );
    return std::string(buffer.data(), copied);
  }

  LumenCoreEncodedCaptureIngress *encoded_capture_ingress::handle() const {
    return handle_;
  }
}

namespace {
  LumenCoreEncodedCaptureIngress *shared_encoded_capture_ingress() {
    static LumenCoreEncodedCaptureIngress ingress;
    return &ingress;
  }

  LumenCoreAudioCaptureIngress *shared_audio_capture_ingress() {
    static LumenCoreAudioCaptureIngress ingress;
    return &ingress;
  }

  LumenCoreCaptureRequestState *shared_capture_request_state() {
    static LumenCoreCaptureRequestState state;
    return &state;
  }
}

const char *LumenCoreBootstrapVersionString(void) {
  static const std::string version = lumen::core::version_string();
  return version.c_str();
}

const char *LumenCoreBootstrapRuntimeDescription(void) {
  static const std::string description = lumen::core::runtime_description();
  return description.c_str();
}

LumenCoreEncodedCaptureIngress *LumenCoreEncodedCaptureIngressCreate(void) {
  return new LumenCoreEncodedCaptureIngress();
}

void LumenCoreEncodedCaptureIngressDestroy(LumenCoreEncodedCaptureIngress *ingress) {
  delete ingress;
}

void LumenCoreEncodedCaptureIngressReset(LumenCoreEncodedCaptureIngress *ingress) {
  if (!ingress) {
    return;
  }

  std::scoped_lock lock(ingress->mutex);
  ingress->frame_count = 0;
  ingress->event_count = 0;
  ingress->dropped_frame_count = 0;
  ingress->dropped_event_count = 0;
  ingress->last_frame.reset();
  ingress->last_event.reset();
  ingress->pending_frames.clear();
  ingress->pending_events.clear();
  ingress->data_cv.notify_all();
}

void LumenCoreEncodedCaptureIngressSetFrameCapacity(
  LumenCoreEncodedCaptureIngress *ingress,
  std::size_t capacity
) {
  if (!ingress) {
    return;
  }

  std::scoped_lock lock(ingress->mutex);
  ingress->frame_capacity = std::max<std::size_t>(1, capacity);
  while (ingress->pending_frames.size() > ingress->frame_capacity) {
    ingress->pending_frames.pop_front();
    ingress->dropped_frame_count += 1;
  }
}

void LumenCoreEncodedCaptureIngressSetEventCapacity(
  LumenCoreEncodedCaptureIngress *ingress,
  std::size_t capacity
) {
  if (!ingress) {
    return;
  }

  std::scoped_lock lock(ingress->mutex);
  ingress->event_capacity = std::max<std::size_t>(1, capacity);
  while (ingress->pending_events.size() > ingress->event_capacity) {
    ingress->pending_events.pop_front();
    ingress->dropped_event_count += 1;
  }
}

void LumenCoreEncodedCaptureIngressConsumeSampleBuffer(
  LumenCoreEncodedCaptureIngress *ingress,
  LumenCoreCaptureCodec codec,
  std::uint64_t source_sequence_number,
  std::uint64_t source_display_time,
  bool has_output_callback_latency_milliseconds,
  double output_callback_latency_milliseconds,
  bool is_key_frame,
  bool is_hdr_signaled,
  bool is_replay,
  CMSampleBufferRef sample_buffer
) {
  LumenCoreEncodedCaptureIngressConsumeSampleBufferWithTileMetadata(
    ingress,
    codec,
    source_sequence_number,
    source_display_time,
    has_output_callback_latency_milliseconds,
    output_callback_latency_milliseconds,
    is_key_frame,
    is_hdr_signaled,
    is_replay,
    single_frame_tile_metadata(),
    sample_buffer
  );
}

void LumenCoreEncodedCaptureIngressConsumeSampleBufferWithTileMetadata(
  LumenCoreEncodedCaptureIngress *ingress,
  LumenCoreCaptureCodec codec,
  std::uint64_t source_sequence_number,
  std::uint64_t source_display_time,
  bool has_output_callback_latency_milliseconds,
  double output_callback_latency_milliseconds,
  bool is_key_frame,
  bool is_hdr_signaled,
  bool is_replay,
  LumenCoreEncodedCaptureTileMetadata tile_metadata,
  CMSampleBufferRef sample_buffer
) {
  if (!ingress) {
    return;
  }

  encoded_frame_state_t frame {};
  frame.codec = codec;
  frame.sample_buffer = std::make_shared<retained_sample_buffer_t>(sample_buffer);
  frame.source_sequence_number = source_sequence_number;
  frame.source_display_time = source_display_time;
  frame.has_output_callback_latency_milliseconds = has_output_callback_latency_milliseconds;
  frame.output_callback_latency_milliseconds = output_callback_latency_milliseconds;
  frame.is_key_frame = is_key_frame;
  frame.is_hdr_signaled = is_hdr_signaled;
  frame.is_replay = is_replay;
  frame.tile_metadata = normalized_tile_metadata(tile_metadata);

  std::scoped_lock lock(ingress->mutex);
  ingress->frame_count += 1;
  ingress->last_frame = frame;
  ingress->pending_frames.push_back(std::move(frame));

  const auto drop_oldest_pending_frame = [&]() {
    const auto dropped_frame_source_display_time = ingress->pending_frames.front().source_display_time;
    ingress->pending_frames.pop_front();
    ingress->dropped_frame_count += 1;
    push_encoded_capture_drop_event_locked(ingress, dropped_frame_source_display_time);
  };

  const auto overflowed = ingress->pending_frames.size() > ingress->frame_capacity;
  while (ingress->pending_frames.size() > ingress->frame_capacity) {
    drop_oldest_pending_frame();
  }

  const auto newest_frame_is_key_frame = !ingress->pending_frames.empty() && ingress->pending_frames.back().is_key_frame;

  // Tiny forwarding queues are intentional low-latency profiles. If they overflow,
  // collapse the backlog to the freshest encoded frame instead of preserving extra
  // dependent frames that will usually arrive too late to be useful. Apply the same
  // collapse when an overflow just delivered a new key frame, because older dependent
  // frames are no longer useful once a fresher recovery point is already queued.
  if (overflowed && (ingress->frame_capacity <= 3 || newest_frame_is_key_frame)) {
    while (ingress->pending_frames.size() > 1) {
      drop_oldest_pending_frame();
    }
  }
  ingress->data_cv.notify_all();
}

void LumenCoreEncodedCaptureIngressConsumeEvent(
  LumenCoreEncodedCaptureIngress *ingress,
  LumenCoreCaptureEventKind kind,
  const char *message,
  bool has_stop_status,
  std::int32_t stop_status,
  bool has_automatic_restart_count,
  std::uint64_t automatic_restart_count,
  bool has_source_display_time,
  std::uint64_t source_display_time
) {
  if (!ingress) {
    return;
  }

  encoded_event_state_t event {};
  event.kind = kind;
  if (message) {
    event.message = message;
  }
  event.has_stop_status = has_stop_status;
  event.stop_status = stop_status;
  event.has_automatic_restart_count = has_automatic_restart_count;
  event.automatic_restart_count = automatic_restart_count;
  event.has_source_display_time = has_source_display_time;
  event.source_display_time = source_display_time;

  std::scoped_lock lock(ingress->mutex);
  ingress->event_count += 1;
  ingress->last_event = event;
  ingress->pending_events.push_back(std::move(event));
  while (ingress->pending_events.size() > ingress->event_capacity) {
    ingress->pending_events.pop_front();
    ingress->dropped_event_count += 1;
  }
  ingress->data_cv.notify_all();
}

LumenCoreEncodedCaptureIngressSnapshot LumenCoreEncodedCaptureIngressCopySnapshot(
  const LumenCoreEncodedCaptureIngress *ingress
) {
  LumenCoreEncodedCaptureIngressSnapshot snapshot {};
  snapshot.last_frame_codec = LumenCoreCaptureCodecUnknown;
  snapshot.last_event_kind = LumenCoreCaptureEventKindUnknown;

  if (!ingress) {
    return snapshot;
  }

  std::scoped_lock lock(ingress->mutex);
  snapshot.frame_count = ingress->frame_count;
  snapshot.event_count = ingress->event_count;
  snapshot.queued_frame_count = ingress->pending_frames.size();
  snapshot.queued_event_count = ingress->pending_events.size();
  snapshot.dropped_frame_count = ingress->dropped_frame_count;
  snapshot.dropped_event_count = ingress->dropped_event_count;

  if (ingress->last_frame.has_value()) {
    const auto &frame = *ingress->last_frame;
    snapshot.has_last_frame = true;
    snapshot.has_last_sample_buffer = frame.sample_buffer && frame.sample_buffer->value != nullptr;
    snapshot.last_frame_codec = frame.codec;
    snapshot.last_frame_payload_size = frame.payload_size();
    snapshot.last_frame_source_sequence_number = frame.source_sequence_number;
    snapshot.last_frame_source_display_time = frame.source_display_time;
    snapshot.last_frame_is_key_frame = frame.is_key_frame;
    snapshot.last_frame_is_hdr_signaled = frame.is_hdr_signaled;
    snapshot.last_frame_tile_metadata = frame.tile_metadata;
  }

  if (ingress->last_event.has_value()) {
    const auto &event = *ingress->last_event;
    snapshot.has_last_event = true;
    snapshot.last_event_kind = event.kind;
    snapshot.last_event_has_stop_status = event.has_stop_status;
    snapshot.last_event_stop_status = event.stop_status;
    snapshot.last_event_has_automatic_restart_count = event.has_automatic_restart_count;
    snapshot.last_event_automatic_restart_count = event.automatic_restart_count;
    snapshot.last_event_has_source_display_time = event.has_source_display_time;
    snapshot.last_event_source_display_time = event.source_display_time;
  }

  return snapshot;
}

CMSampleBufferRef LumenCoreEncodedCaptureIngressCreateRetainedLastSampleBuffer(
  const LumenCoreEncodedCaptureIngress *ingress
) {
  if (!ingress) {
    return nullptr;
  }

  std::scoped_lock lock(ingress->mutex);
  if (!ingress->last_frame.has_value() ||
      !ingress->last_frame->sample_buffer ||
      !ingress->last_frame->sample_buffer->value) {
    return nullptr;
  }

  return reinterpret_cast<CMSampleBufferRef>(
    const_cast<void *>(CFRetain(ingress->last_frame->sample_buffer->value))
  );
}

LumenCoreEncodedCaptureFrameRecord LumenCoreEncodedCaptureIngressPopNextFrame(
  LumenCoreEncodedCaptureIngress *ingress,
  CMSampleBufferRef *retained_sample_buffer_out
) {
  LumenCoreEncodedCaptureFrameRecord record {};

  if (retained_sample_buffer_out) {
    *retained_sample_buffer_out = nullptr;
  }

  if (!ingress) {
    return record;
  }

  std::scoped_lock lock(ingress->mutex);
  if (ingress->pending_frames.empty()) {
    return record;
  }

  auto frame = std::move(ingress->pending_frames.front());
  ingress->pending_frames.pop_front();
  record = frame.record();
  if (retained_sample_buffer_out && frame.sample_buffer && frame.sample_buffer->value) {
    *retained_sample_buffer_out = reinterpret_cast<CMSampleBufferRef>(
      const_cast<void *>(CFRetain(frame.sample_buffer->value))
    );
  }
  return record;
}

LumenCoreEncodedCaptureEventRecord LumenCoreEncodedCaptureIngressPopNextEvent(
  LumenCoreEncodedCaptureIngress *ingress,
  char *message_destination,
  size_t message_capacity
) {
  LumenCoreEncodedCaptureEventRecord record {};

  if (!ingress) {
    return record;
  }

  std::scoped_lock lock(ingress->mutex);
  if (ingress->pending_events.empty()) {
    return record;
  }

  auto event = std::move(ingress->pending_events.front());
  ingress->pending_events.pop_front();
  record = event.record();

  const auto copy_size = std::min(message_capacity, event.message.size());
  if (copy_size > 0 && message_destination) {
    std::memcpy(message_destination, event.message.data(), copy_size);
  }
  return record;
}

size_t LumenCoreEncodedCaptureIngressCopyLastEventMessage(
  const LumenCoreEncodedCaptureIngress *ingress,
  char *destination,
  size_t capacity
) {
  if (!ingress) {
    return 0;
  }

  std::scoped_lock lock(ingress->mutex);
  if (!ingress->last_event.has_value()) {
    return 0;
  }

  const auto &message = ingress->last_event->message;
  const auto copy_size = std::min(capacity, message.size());
  if (copy_size > 0 && destination) {
    std::memcpy(destination, message.data(), copy_size);
  }
  return copy_size;
}

LumenCoreEncodedCaptureIngress *LumenCoreSharedEncodedCaptureIngress(void) {
  return shared_encoded_capture_ingress();
}

void LumenCoreEncodedCaptureIngressSetProducerActive(
  LumenCoreEncodedCaptureIngress *ingress,
  bool active
) {
  if (!ingress) {
    return;
  }

  {
    std::scoped_lock lock(ingress->mutex);
    ingress->producer_active = active;
  }
  ingress->data_cv.notify_all();
}

bool LumenCoreEncodedCaptureIngressIsProducerActive(
  const LumenCoreEncodedCaptureIngress *ingress
) {
  if (!ingress) {
    return false;
  }

  std::scoped_lock lock(ingress->mutex);
  return ingress->producer_active;
}

bool LumenCoreEncodedCaptureIngressWaitForData(
  LumenCoreEncodedCaptureIngress *ingress,
  uint32_t timeout_milliseconds
) {
  if (!ingress) {
    return false;
  }

  std::unique_lock lock(ingress->mutex);
  const auto has_pending = [&]() {
    return ingress_has_pending(ingress->pending_frames, ingress->pending_events);
  };

  if (has_pending()) {
    return true;
  }

  ingress->data_cv.wait_for(lock, std::chrono::milliseconds(timeout_milliseconds), [&]() {
    return has_pending() || !ingress->producer_active;
  });
  return has_pending();
}

bool LumenCoreEncodedCaptureIngressWaitForProducerActive(
  LumenCoreEncodedCaptureIngress *ingress,
  uint32_t timeout_milliseconds
) {
  if (!ingress) {
    return false;
  }

  std::unique_lock lock(ingress->mutex);
  if (ingress->producer_active) {
    return true;
  }

  ingress->data_cv.wait_for(lock, std::chrono::milliseconds(timeout_milliseconds), [&]() {
    return ingress->producer_active;
  });
  return ingress->producer_active;
}

LumenCoreAudioCaptureIngress *LumenCoreAudioCaptureIngressCreate(void) {
  return new LumenCoreAudioCaptureIngress();
}

void LumenCoreAudioCaptureIngressDestroy(LumenCoreAudioCaptureIngress *ingress) {
  delete ingress;
}

void LumenCoreAudioCaptureIngressReset(LumenCoreAudioCaptureIngress *ingress) {
  if (!ingress) {
    return;
  }

  std::scoped_lock lock(ingress->mutex);
  ingress->frame_count = 0;
  ingress->event_count = 0;
  ingress->dropped_frame_count = 0;
  ingress->dropped_event_count = 0;
  ingress->last_frame.reset();
  ingress->last_event.reset();
  ingress->pending_frames.clear();
  ingress->pending_events.clear();
  ingress->data_cv.notify_all();
}

void LumenCoreAudioCaptureIngressSetFrameCapacity(
  LumenCoreAudioCaptureIngress *ingress,
  std::size_t capacity
) {
  if (!ingress) {
    return;
  }

  std::scoped_lock lock(ingress->mutex);
  ingress->frame_capacity = std::max<std::size_t>(1, capacity);
  while (ingress->pending_frames.size() > ingress->frame_capacity) {
    ingress->pending_frames.pop_front();
    ingress->dropped_frame_count += 1;
  }
}

void LumenCoreAudioCaptureIngressSetEventCapacity(
  LumenCoreAudioCaptureIngress *ingress,
  std::size_t capacity
) {
  if (!ingress) {
    return;
  }

  std::scoped_lock lock(ingress->mutex);
  ingress->event_capacity = std::max<std::size_t>(1, capacity);
  while (ingress->pending_events.size() > ingress->event_capacity) {
    ingress->pending_events.pop_front();
    ingress->dropped_event_count += 1;
  }
}

void LumenCoreAudioCaptureIngressConsumePCMFloat32(
  LumenCoreAudioCaptureIngress *ingress,
  std::uint64_t sequence_number,
  std::uint64_t host_time_nanoseconds,
  std::int32_t sample_rate,
  std::int32_t channel_count,
  std::int32_t frame_count,
  const void *pcm_float32le,
  std::size_t pcm_byte_count
) {
  if (!ingress || !pcm_float32le || pcm_byte_count == 0) {
    return;
  }

  audio_frame_state_t frame {};
  frame.sequence_number = sequence_number;
  frame.host_time_nanoseconds = host_time_nanoseconds;
  frame.sample_rate = sample_rate;
  frame.channel_count = channel_count;
  frame.frame_count = frame_count;
  frame.pcm_float32le.resize(pcm_byte_count);
  std::memcpy(frame.pcm_float32le.data(), pcm_float32le, pcm_byte_count);

  std::scoped_lock lock(ingress->mutex);
  ingress->frame_count += 1;
  ingress->last_frame = frame;
  ingress->pending_frames.push_back(std::move(frame));
  while (ingress->pending_frames.size() > ingress->frame_capacity) {
    ingress->pending_frames.pop_front();
    ingress->dropped_frame_count += 1;
  }
  ingress->data_cv.notify_all();
}

void LumenCoreAudioCaptureIngressConsumeEvent(
  LumenCoreAudioCaptureIngress *ingress,
  LumenCoreCaptureEventKind kind,
  const char *message,
  bool has_stop_status,
  std::int32_t stop_status,
  bool has_automatic_restart_count,
  std::uint64_t automatic_restart_count,
  bool has_source_sequence_number,
  std::uint64_t source_sequence_number
) {
  if (!ingress) {
    return;
  }

  audio_event_state_t event {};
  event.kind = kind;
  if (message) {
    event.message = message;
  }
  event.has_stop_status = has_stop_status;
  event.stop_status = stop_status;
  event.has_automatic_restart_count = has_automatic_restart_count;
  event.automatic_restart_count = automatic_restart_count;
  event.has_source_sequence_number = has_source_sequence_number;
  event.source_sequence_number = source_sequence_number;

  std::scoped_lock lock(ingress->mutex);
  ingress->event_count += 1;
  ingress->last_event = event;
  ingress->pending_events.push_back(std::move(event));
  while (ingress->pending_events.size() > ingress->event_capacity) {
    ingress->pending_events.pop_front();
    ingress->dropped_event_count += 1;
  }
  ingress->data_cv.notify_all();
}

LumenCoreAudioCaptureIngressSnapshot LumenCoreAudioCaptureIngressCopySnapshot(
  const LumenCoreAudioCaptureIngress *ingress
) {
  LumenCoreAudioCaptureIngressSnapshot snapshot {};
  snapshot.last_event_kind = LumenCoreCaptureEventKindUnknown;

  if (!ingress) {
    return snapshot;
  }

  std::scoped_lock lock(ingress->mutex);
  snapshot.frame_count = ingress->frame_count;
  snapshot.event_count = ingress->event_count;
  snapshot.queued_frame_count = ingress->pending_frames.size();
  snapshot.queued_event_count = ingress->pending_events.size();
  snapshot.dropped_frame_count = ingress->dropped_frame_count;
  snapshot.dropped_event_count = ingress->dropped_event_count;

  if (ingress->last_frame.has_value()) {
    const auto &frame = *ingress->last_frame;
    snapshot.has_last_frame = true;
    snapshot.last_frame_sequence_number = frame.sequence_number;
    snapshot.last_frame_host_time_nanoseconds = frame.host_time_nanoseconds;
    snapshot.last_frame_sample_rate = frame.sample_rate;
    snapshot.last_frame_channel_count = frame.channel_count;
    snapshot.last_frame_frame_count = frame.frame_count;
    snapshot.last_frame_pcm_byte_count = frame.pcm_float32le.size();
  }

  if (ingress->last_event.has_value()) {
    const auto &event = *ingress->last_event;
    snapshot.has_last_event = true;
    snapshot.last_event_kind = event.kind;
    snapshot.last_event_has_stop_status = event.has_stop_status;
    snapshot.last_event_stop_status = event.stop_status;
    snapshot.last_event_has_automatic_restart_count = event.has_automatic_restart_count;
    snapshot.last_event_automatic_restart_count = event.automatic_restart_count;
    snapshot.last_event_has_source_sequence_number = event.has_source_sequence_number;
    snapshot.last_event_source_sequence_number = event.source_sequence_number;
  }

  return snapshot;
}

LumenCoreAudioCaptureFrameRecord LumenCoreAudioCaptureIngressPopNextFrame(
  LumenCoreAudioCaptureIngress *ingress,
  void *pcm_destination,
  std::size_t pcm_capacity,
  std::size_t *copied_size_out
) {
  LumenCoreAudioCaptureFrameRecord record {};
  if (copied_size_out) {
    *copied_size_out = 0;
  }

  if (!ingress) {
    return record;
  }

  std::scoped_lock lock(ingress->mutex);
  if (ingress->pending_frames.empty()) {
    return record;
  }

  auto frame = std::move(ingress->pending_frames.front());
  ingress->pending_frames.pop_front();
  record = frame.record();

  if (pcm_destination && pcm_capacity > 0) {
    const auto copy_size = std::min(pcm_capacity, frame.pcm_float32le.size());
    std::memcpy(pcm_destination, frame.pcm_float32le.data(), copy_size);
    if (copied_size_out) {
      *copied_size_out = copy_size;
    }
  }

  return record;
}

LumenCoreAudioCaptureEventRecord LumenCoreAudioCaptureIngressPopNextEvent(
  LumenCoreAudioCaptureIngress *ingress,
  char *message_destination,
  size_t message_capacity
) {
  LumenCoreAudioCaptureEventRecord record {};

  if (!ingress) {
    return record;
  }

  std::scoped_lock lock(ingress->mutex);
  if (ingress->pending_events.empty()) {
    return record;
  }

  auto event = std::move(ingress->pending_events.front());
  ingress->pending_events.pop_front();
  record = event.record();

  const auto copy_size = std::min(message_capacity, event.message.size());
  if (copy_size > 0 && message_destination) {
    std::memcpy(message_destination, event.message.data(), copy_size);
  }
  return record;
}

size_t LumenCoreAudioCaptureIngressCopyLastEventMessage(
  const LumenCoreAudioCaptureIngress *ingress,
  char *destination,
  size_t capacity
) {
  if (!ingress) {
    return 0;
  }

  std::scoped_lock lock(ingress->mutex);
  if (!ingress->last_event.has_value()) {
    return 0;
  }

  const auto &message = ingress->last_event->message;
  const auto copy_size = std::min(capacity, message.size());
  if (copy_size > 0 && destination) {
    std::memcpy(destination, message.data(), copy_size);
  }
  return copy_size;
}

LumenCoreAudioCaptureIngress *LumenCoreSharedAudioCaptureIngress(void) {
  return shared_audio_capture_ingress();
}

void LumenCoreAudioCaptureIngressSetProducerActive(
  LumenCoreAudioCaptureIngress *ingress,
  bool active
) {
  if (!ingress) {
    return;
  }

  {
    std::scoped_lock lock(ingress->mutex);
    ingress->producer_active = active;
  }
  ingress->data_cv.notify_all();
}

bool LumenCoreAudioCaptureIngressIsProducerActive(
  const LumenCoreAudioCaptureIngress *ingress
) {
  if (!ingress) {
    return false;
  }

  std::scoped_lock lock(ingress->mutex);
  return ingress->producer_active;
}

bool LumenCoreAudioCaptureIngressWaitForData(
  LumenCoreAudioCaptureIngress *ingress,
  uint32_t timeout_milliseconds
) {
  if (!ingress) {
    return false;
  }

  std::unique_lock lock(ingress->mutex);
  const auto has_pending = [&]() {
    return ingress_has_pending(ingress->pending_frames, ingress->pending_events);
  };

  if (has_pending()) {
    return true;
  }

  ingress->data_cv.wait_for(lock, std::chrono::milliseconds(timeout_milliseconds), [&]() {
    return has_pending() || !ingress->producer_active;
  });
  return has_pending();
}

bool LumenCoreAudioCaptureIngressWaitForProducerActive(
  LumenCoreAudioCaptureIngress *ingress,
  uint32_t timeout_milliseconds
) {
  if (!ingress) {
    return false;
  }

  std::unique_lock lock(ingress->mutex);
  if (ingress->producer_active) {
    return true;
  }

  ingress->data_cv.wait_for(lock, std::chrono::milliseconds(timeout_milliseconds), [&]() {
    return ingress->producer_active;
  });
  return ingress->producer_active;
}

LumenCoreCaptureRequestSnapshot LumenCoreCaptureRequestCopySnapshot(void) {
  auto *state = shared_capture_request_state();
  std::scoped_lock lock(state->mutex);
  return state->snapshot;
}

bool LumenCoreCaptureRequestWaitForGenerationChange(
  uint64_t observed_generation,
  uint32_t timeout_milliseconds
) {
  auto *state = shared_capture_request_state();
  std::unique_lock lock(state->mutex);
  if (state->snapshot.generation != observed_generation) {
    return true;
  }

  state->change_cv.wait_for(lock, std::chrono::milliseconds(timeout_milliseconds), [&]() {
    return state->snapshot.generation != observed_generation;
  });
  return state->snapshot.generation != observed_generation;
}

void LumenCoreCaptureRequestPublishVideo(
  uint32_t display_id,
  LumenCoreCaptureCodec codec,
  LumenCoreCapturePreprocessStrategy preprocess_strategy,
  LumenCoreCaptureQueueProfile queue_profile,
  bool show_cursor,
  int32_t target_frame_rate,
  int32_t target_video_bitrate_kbps,
  int32_t requested_width,
  int32_t requested_height,
  LumenCoreSinkRequest sink_request,
  LumenCoreEffectiveDisplayState effective_display_state
) {
  auto *state = shared_capture_request_state();
  {
    std::scoped_lock lock(state->mutex);
    state->snapshot.generation += 1;
    state->snapshot.video_generation += 1;
    state->snapshot.video_requested = codec != LumenCoreCaptureCodecUnknown;
    state->snapshot.display_id = display_id;
    state->snapshot.codec = codec;
    state->snapshot.preprocess_strategy = preprocess_strategy;
    state->snapshot.queue_profile = queue_profile;
    state->snapshot.show_cursor = show_cursor;
    state->snapshot.target_frame_rate = std::max<int32_t>(target_frame_rate, 1);
    state->snapshot.target_video_bitrate_kbps = std::max<int32_t>(target_video_bitrate_kbps, 0);
    state->snapshot.requested_width = std::max<int32_t>(requested_width, 0);
    state->snapshot.requested_height = std::max<int32_t>(requested_height, 0);
    state->snapshot.sink_request.mode.hidpi = sink_request.mode.hidpi;
    state->snapshot.sink_request.mode.scale_explicit = sink_request.mode.scale_explicit;
    state->snapshot.sink_request.mode.mode_is_logical = sink_request.mode.mode_is_logical;
    state->snapshot.sink_request.mode.scale_percent = std::max<int32_t>(sink_request.mode.scale_percent, 0);
    state->snapshot.sink_request.capability.gamut = std::max<int32_t>(sink_request.capability.gamut, 0);
    state->snapshot.sink_request.capability.transfer = std::max<int32_t>(sink_request.capability.transfer, 0);
    state->snapshot.sink_request.capability.current_edr_headroom = std::max(sink_request.capability.current_edr_headroom, 0.0f);
    state->snapshot.sink_request.capability.potential_edr_headroom = std::max(sink_request.capability.potential_edr_headroom, 0.0f);
    state->snapshot.sink_request.capability.current_peak_luminance_nits = std::max<int32_t>(sink_request.capability.current_peak_luminance_nits, 0);
    state->snapshot.sink_request.capability.potential_peak_luminance_nits = std::max<int32_t>(sink_request.capability.potential_peak_luminance_nits, 0);
    state->snapshot.sink_request.capability.supports_frame_gated_hdr = sink_request.capability.supports_frame_gated_hdr;
    state->snapshot.sink_request.capability.supports_hdr_tile_overlay = sink_request.capability.supports_hdr_tile_overlay;
    state->snapshot.sink_request.capability.supports_per_frame_hdr_metadata = sink_request.capability.supports_per_frame_hdr_metadata;
    state->snapshot.sink_request.capability.supports_encoded_tile_stream = sink_request.capability.supports_encoded_tile_stream;
    state->snapshot.sink_request.dynamic_range_transport = sink_request.dynamic_range_transport;
    state->snapshot.effective_display_state.gamut = std::max<int32_t>(effective_display_state.gamut, 0);
    state->snapshot.effective_display_state.transfer = std::max<int32_t>(effective_display_state.transfer, 0);
    state->snapshot.effective_display_state.has_hdr_static_metadata = effective_display_state.has_hdr_static_metadata;
    state->snapshot.effective_display_state.hdr_static_metadata = effective_display_state.hdr_static_metadata;
  }
  state->change_cv.notify_all();
}

void LumenCoreCaptureRequestPublishAudio(
  LumenCoreAudioCaptureSourceKind source_kind,
  uint32_t display_id,
  bool excludes_current_process_audio,
  int32_t sample_rate,
  int32_t channel_count,
  int32_t frame_size
) {
  auto *state = shared_capture_request_state();
  {
    std::scoped_lock lock(state->mutex);
    state->snapshot.generation += 1;
    state->snapshot.audio_generation += 1;
    state->snapshot.audio_requested = source_kind != LumenCoreAudioCaptureSourceKindUnknown;
    state->snapshot.audio_source_kind = source_kind;
    state->snapshot.display_id = display_id;
    state->snapshot.audio_excludes_current_process = excludes_current_process_audio;
    state->snapshot.audio_sample_rate = std::max<int32_t>(sample_rate, 1);
    state->snapshot.audio_channel_count = std::max<int32_t>(channel_count, 1);
    state->snapshot.audio_frame_size = std::max<int32_t>(frame_size, 1);
  }
  state->change_cv.notify_all();
}

void LumenCoreCaptureRequestClear(void) {
  auto *state = shared_capture_request_state();
  {
    std::scoped_lock lock(state->mutex);
    const auto generation = state->snapshot.generation + 1;
    const auto video_generation = state->snapshot.video_generation + 1;
    const auto audio_generation = state->snapshot.audio_generation + 1;
    state->snapshot = {};
    state->snapshot.generation = generation;
    state->snapshot.video_generation = video_generation;
    state->snapshot.audio_generation = audio_generation;
    state->snapshot.codec = LumenCoreCaptureCodecUnknown;
    state->snapshot.audio_source_kind = LumenCoreAudioCaptureSourceKindUnknown;
    state->snapshot.preprocess_strategy = LumenCoreCapturePreprocessStrategyNone;
    state->snapshot.queue_profile = LumenCoreCaptureQueueProfileAuto;
  }
  state->change_cv.notify_all();
}
