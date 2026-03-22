#include "ApolloCore.h"
#include "ApolloCoreInternal.hpp"

#include <algorithm>
#include <array>
#include <cstring>
#include <deque>
#include <mutex>
#include <optional>
#include <string>
#include <utility>

namespace {
  constexpr std::size_t default_frame_capacity = 8;
  constexpr std::size_t default_event_capacity = 32;

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
    ApolloCoreCaptureEventKind kind = ApolloCoreCaptureEventKindUnknown;
    std::string message;
    bool has_stop_status = false;
    std::int32_t stop_status = 0;
    bool has_automatic_restart_count = false;
    std::uint64_t automatic_restart_count = 0;
    bool has_source_display_time = false;
    std::uint64_t source_display_time = 0;

    ApolloCoreEncodedCaptureEventRecord record() const {
      ApolloCoreEncodedCaptureEventRecord record {};
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
    ApolloCoreCaptureCodec codec = ApolloCoreCaptureCodecUnknown;
    retained_sample_buffer_t sample_buffer;
    std::uint64_t source_sequence_number = 0;
    std::uint64_t source_display_time = 0;
    bool has_output_callback_latency_milliseconds = false;
    double output_callback_latency_milliseconds = 0.0;
    bool is_key_frame = false;
    bool is_hdr_signaled = false;

    std::size_t payload_size() const {
      if (!sample_buffer.value) {
        return 0;
      }

      CMBlockBufferRef block_buffer = CMSampleBufferGetDataBuffer(sample_buffer.value);
      if (!block_buffer) {
        return 0;
      }

      return static_cast<std::size_t>(CMBlockBufferGetDataLength(block_buffer));
    }

    ApolloCoreEncodedCaptureFrameRecord record() const {
      ApolloCoreEncodedCaptureFrameRecord record {};
      record.has_value = true;
      record.codec = codec;
      record.payload_size = payload_size();
      record.source_sequence_number = source_sequence_number;
      record.source_display_time = source_display_time;
      record.has_output_callback_latency_milliseconds = has_output_callback_latency_milliseconds;
      record.output_callback_latency_milliseconds = output_callback_latency_milliseconds;
      record.is_key_frame = is_key_frame;
      record.is_hdr_signaled = is_hdr_signaled;
      return record;
    }
  };
}

struct ApolloCoreEncodedCaptureIngress {
  mutable std::mutex mutex;
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

namespace apollo::core {
  std::string version_string() {
    return "ApolloCore bootstrap";
  }

  std::string runtime_description() {
    return "C and C++ compatibility surface for the Swift/Tuist Apollo shell.";
  }

  encoded_capture_ingress::encoded_capture_ingress() :
      handle_(ApolloCoreEncodedCaptureIngressCreate()) {
  }

  encoded_capture_ingress::~encoded_capture_ingress() {
    ApolloCoreEncodedCaptureIngressDestroy(handle_);
    handle_ = nullptr;
  }

  encoded_capture_ingress::encoded_capture_ingress(encoded_capture_ingress &&other) noexcept :
      handle_(std::exchange(other.handle_, nullptr)) {
  }

  encoded_capture_ingress &encoded_capture_ingress::operator=(encoded_capture_ingress &&other) noexcept {
    if (this == &other) {
      return *this;
    }

    ApolloCoreEncodedCaptureIngressDestroy(handle_);
    handle_ = std::exchange(other.handle_, nullptr);
    return *this;
  }

  void encoded_capture_ingress::reset() {
    ApolloCoreEncodedCaptureIngressReset(handle_);
  }

  void encoded_capture_ingress::set_frame_capacity(std::size_t capacity) {
    ApolloCoreEncodedCaptureIngressSetFrameCapacity(handle_, capacity);
  }

  void encoded_capture_ingress::set_event_capacity(std::size_t capacity) {
    ApolloCoreEncodedCaptureIngressSetEventCapacity(handle_, capacity);
  }

  void encoded_capture_ingress::consume_sample_buffer(
    ApolloCoreCaptureCodec codec,
    std::uint64_t source_sequence_number,
    std::uint64_t source_display_time,
    bool has_output_callback_latency_milliseconds,
    double output_callback_latency_milliseconds,
    bool is_key_frame,
    bool is_hdr_signaled,
    CMSampleBufferRef sample_buffer
  ) {
    ApolloCoreEncodedCaptureIngressConsumeSampleBuffer(
      handle_,
      codec,
      source_sequence_number,
      source_display_time,
      has_output_callback_latency_milliseconds,
      output_callback_latency_milliseconds,
      is_key_frame,
      is_hdr_signaled,
      sample_buffer
    );
  }

  void encoded_capture_ingress::consume_event(
    ApolloCoreCaptureEventKind kind,
    const char *message,
    bool has_stop_status,
    std::int32_t stop_status,
    bool has_automatic_restart_count,
    std::uint64_t automatic_restart_count,
    bool has_source_display_time,
    std::uint64_t source_display_time
  ) {
    ApolloCoreEncodedCaptureIngressConsumeEvent(
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

  ApolloCoreEncodedCaptureIngressSnapshot encoded_capture_ingress::snapshot() const {
    return ApolloCoreEncodedCaptureIngressCopySnapshot(handle_);
  }

  CMSampleBufferRef encoded_capture_ingress::create_retained_last_sample_buffer() const {
    return ApolloCoreEncodedCaptureIngressCreateRetainedLastSampleBuffer(handle_);
  }

  ApolloCoreEncodedCaptureFrameRecord encoded_capture_ingress::pop_next_frame(
    CMSampleBufferRef *sample_buffer_out
  ) {
    return ApolloCoreEncodedCaptureIngressPopNextFrame(handle_, sample_buffer_out);
  }

  ApolloCoreEncodedCaptureEventRecord encoded_capture_ingress::pop_next_event(
    char *message_destination,
    std::size_t message_capacity
  ) {
    return ApolloCoreEncodedCaptureIngressPopNextEvent(handle_, message_destination, message_capacity);
  }

  std::string encoded_capture_ingress::copy_last_event_message() const {
    std::array<char, 512> buffer {};
    const auto copied = ApolloCoreEncodedCaptureIngressCopyLastEventMessage(
      handle_,
      buffer.data(),
      buffer.size()
    );
    return std::string(buffer.data(), copied);
  }

  ApolloCoreEncodedCaptureIngress *encoded_capture_ingress::handle() const {
    return handle_;
  }
}

const char *ApolloCoreBootstrapVersionString(void) {
  static const std::string version = apollo::core::version_string();
  return version.c_str();
}

const char *ApolloCoreBootstrapRuntimeDescription(void) {
  static const std::string description = apollo::core::runtime_description();
  return description.c_str();
}

ApolloCoreEncodedCaptureIngress *ApolloCoreEncodedCaptureIngressCreate(void) {
  return new ApolloCoreEncodedCaptureIngress();
}

void ApolloCoreEncodedCaptureIngressDestroy(ApolloCoreEncodedCaptureIngress *ingress) {
  delete ingress;
}

void ApolloCoreEncodedCaptureIngressReset(ApolloCoreEncodedCaptureIngress *ingress) {
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
}

void ApolloCoreEncodedCaptureIngressSetFrameCapacity(
  ApolloCoreEncodedCaptureIngress *ingress,
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

void ApolloCoreEncodedCaptureIngressSetEventCapacity(
  ApolloCoreEncodedCaptureIngress *ingress,
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

void ApolloCoreEncodedCaptureIngressConsumeSampleBuffer(
  ApolloCoreEncodedCaptureIngress *ingress,
  ApolloCoreCaptureCodec codec,
  std::uint64_t source_sequence_number,
  std::uint64_t source_display_time,
  bool has_output_callback_latency_milliseconds,
  double output_callback_latency_milliseconds,
  bool is_key_frame,
  bool is_hdr_signaled,
  CMSampleBufferRef sample_buffer
) {
  if (!ingress) {
    return;
  }

  encoded_frame_state_t frame {};
  frame.codec = codec;
  frame.sample_buffer = retained_sample_buffer_t(sample_buffer);
  frame.source_sequence_number = source_sequence_number;
  frame.source_display_time = source_display_time;
  frame.has_output_callback_latency_milliseconds = has_output_callback_latency_milliseconds;
  frame.output_callback_latency_milliseconds = output_callback_latency_milliseconds;
  frame.is_key_frame = is_key_frame;
  frame.is_hdr_signaled = is_hdr_signaled;

  std::scoped_lock lock(ingress->mutex);
  ingress->frame_count += 1;
  ingress->last_frame = frame;
  ingress->pending_frames.push_back(std::move(frame));
  while (ingress->pending_frames.size() > ingress->frame_capacity) {
    ingress->pending_frames.pop_front();
    ingress->dropped_frame_count += 1;
  }
}

void ApolloCoreEncodedCaptureIngressConsumeEvent(
  ApolloCoreEncodedCaptureIngress *ingress,
  ApolloCoreCaptureEventKind kind,
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
}

ApolloCoreEncodedCaptureIngressSnapshot ApolloCoreEncodedCaptureIngressCopySnapshot(
  const ApolloCoreEncodedCaptureIngress *ingress
) {
  ApolloCoreEncodedCaptureIngressSnapshot snapshot {};
  snapshot.last_frame_codec = ApolloCoreCaptureCodecUnknown;
  snapshot.last_event_kind = ApolloCoreCaptureEventKindUnknown;

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
    snapshot.has_last_sample_buffer = frame.sample_buffer.value != nullptr;
    snapshot.last_frame_codec = frame.codec;
    snapshot.last_frame_payload_size = frame.payload_size();
    snapshot.last_frame_source_sequence_number = frame.source_sequence_number;
    snapshot.last_frame_source_display_time = frame.source_display_time;
    snapshot.last_frame_is_key_frame = frame.is_key_frame;
    snapshot.last_frame_is_hdr_signaled = frame.is_hdr_signaled;
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

CMSampleBufferRef ApolloCoreEncodedCaptureIngressCreateRetainedLastSampleBuffer(
  const ApolloCoreEncodedCaptureIngress *ingress
) {
  if (!ingress) {
    return nullptr;
  }

  std::scoped_lock lock(ingress->mutex);
  if (!ingress->last_frame.has_value() || !ingress->last_frame->sample_buffer.value) {
    return nullptr;
  }

  return reinterpret_cast<CMSampleBufferRef>(const_cast<void *>(CFRetain(ingress->last_frame->sample_buffer.value)));
}

ApolloCoreEncodedCaptureFrameRecord ApolloCoreEncodedCaptureIngressPopNextFrame(
  ApolloCoreEncodedCaptureIngress *ingress,
  CMSampleBufferRef *retained_sample_buffer_out
) {
  ApolloCoreEncodedCaptureFrameRecord record {};

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
  if (retained_sample_buffer_out && frame.sample_buffer.value) {
    *retained_sample_buffer_out = reinterpret_cast<CMSampleBufferRef>(const_cast<void *>(CFRetain(frame.sample_buffer.value)));
  }
  return record;
}

ApolloCoreEncodedCaptureEventRecord ApolloCoreEncodedCaptureIngressPopNextEvent(
  ApolloCoreEncodedCaptureIngress *ingress,
  char *message_destination,
  size_t message_capacity
) {
  ApolloCoreEncodedCaptureEventRecord record {};

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

size_t ApolloCoreEncodedCaptureIngressCopyLastEventMessage(
  const ApolloCoreEncodedCaptureIngress *ingress,
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
