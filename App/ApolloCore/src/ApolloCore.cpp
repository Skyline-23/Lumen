#include "ApolloCore.h"
#include "ApolloCore.hpp"

#include <array>
#include <algorithm>
#include <cstring>
#include <mutex>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace {
  struct encoded_event_state_t {
    ApolloCoreCaptureEventKind kind = ApolloCoreCaptureEventKindUnknown;
    std::string message;
    bool has_stop_status = false;
    std::int32_t stop_status = 0;
    bool has_automatic_restart_count = false;
    std::uint64_t automatic_restart_count = 0;
    bool has_source_display_time = false;
    std::uint64_t source_display_time = 0;
  };

  struct encoded_frame_state_t {
    ApolloCoreCaptureCodec codec = ApolloCoreCaptureCodecUnknown;
    std::vector<std::uint8_t> payload;
    std::uint64_t source_sequence_number = 0;
    std::uint64_t source_display_time = 0;
    bool has_output_callback_latency_milliseconds = false;
    double output_callback_latency_milliseconds = 0.0;
    bool is_key_frame = false;
    bool is_hdr_signaled = false;
  };
}

struct ApolloCoreEncodedCaptureConsumer {
  mutable std::mutex mutex;
  std::uint64_t frame_count = 0;
  std::uint64_t event_count = 0;
  std::optional<encoded_frame_state_t> last_frame;
  std::optional<encoded_event_state_t> last_event;
};

namespace apollo::core {
  std::string version_string() {
    return "ApolloCore bootstrap";
  }

  std::string runtime_description() {
    return "C and C++ compatibility surface for the Swift/Tuist Apollo shell.";
  }

  encoded_capture_consumer::encoded_capture_consumer() :
      handle_(ApolloCoreEncodedCaptureConsumerCreate()) {
  }

  encoded_capture_consumer::~encoded_capture_consumer() {
    ApolloCoreEncodedCaptureConsumerDestroy(handle_);
    handle_ = nullptr;
  }

  encoded_capture_consumer::encoded_capture_consumer(encoded_capture_consumer &&other) noexcept :
      handle_(std::exchange(other.handle_, nullptr)) {
  }

  encoded_capture_consumer &encoded_capture_consumer::operator=(encoded_capture_consumer &&other) noexcept {
    if (this == &other) {
      return *this;
    }

    ApolloCoreEncodedCaptureConsumerDestroy(handle_);
    handle_ = std::exchange(other.handle_, nullptr);
    return *this;
  }

  void encoded_capture_consumer::reset() {
    ApolloCoreEncodedCaptureConsumerReset(handle_);
  }

  void encoded_capture_consumer::consume_frame(
    ApolloCoreCaptureCodec codec,
    std::uint64_t source_sequence_number,
    std::uint64_t source_display_time,
    bool has_output_callback_latency_milliseconds,
    double output_callback_latency_milliseconds,
    bool is_key_frame,
    bool is_hdr_signaled,
    const std::uint8_t *payload_bytes,
    std::size_t payload_size
  ) {
    ApolloCoreEncodedCaptureConsumerConsumeFrame(
      handle_,
      codec,
      source_sequence_number,
      source_display_time,
      has_output_callback_latency_milliseconds,
      output_callback_latency_milliseconds,
      is_key_frame,
      is_hdr_signaled,
      payload_bytes,
      payload_size
    );
  }

  void encoded_capture_consumer::consume_event(
    ApolloCoreCaptureEventKind kind,
    const char *message,
    bool has_stop_status,
    std::int32_t stop_status,
    bool has_automatic_restart_count,
    std::uint64_t automatic_restart_count,
    bool has_source_display_time,
    std::uint64_t source_display_time
  ) {
    ApolloCoreEncodedCaptureConsumerConsumeEvent(
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

  ApolloCoreEncodedCaptureConsumerSnapshot encoded_capture_consumer::snapshot() const {
    return ApolloCoreEncodedCaptureConsumerCopySnapshot(handle_);
  }

  std::vector<std::uint8_t> encoded_capture_consumer::copy_last_frame_payload() const {
    const auto state = snapshot();
    if (!state.has_last_frame || state.last_frame_payload_size == 0) {
      return {};
    }

    std::vector<std::uint8_t> payload(state.last_frame_payload_size);
    const auto copied = ApolloCoreEncodedCaptureConsumerCopyLastFramePayload(
      handle_,
      payload.data(),
      payload.size()
    );
    payload.resize(copied);
    return payload;
  }

  std::string encoded_capture_consumer::copy_last_event_message() const {
    std::array<char, 512> buffer {};
    const auto copied = ApolloCoreEncodedCaptureConsumerCopyLastEventMessage(
      handle_,
      buffer.data(),
      buffer.size()
    );
    return std::string(buffer.data(), copied);
  }

  ApolloCoreEncodedCaptureConsumer *encoded_capture_consumer::handle() const {
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

ApolloCoreEncodedCaptureConsumer *ApolloCoreEncodedCaptureConsumerCreate(void) {
  return new ApolloCoreEncodedCaptureConsumer();
}

void ApolloCoreEncodedCaptureConsumerDestroy(ApolloCoreEncodedCaptureConsumer *consumer) {
  delete consumer;
}

void ApolloCoreEncodedCaptureConsumerReset(ApolloCoreEncodedCaptureConsumer *consumer) {
  if (!consumer) {
    return;
  }

  std::scoped_lock lock(consumer->mutex);
  consumer->frame_count = 0;
  consumer->event_count = 0;
  consumer->last_frame.reset();
  consumer->last_event.reset();
}

void ApolloCoreEncodedCaptureConsumerConsumeFrame(
  ApolloCoreEncodedCaptureConsumer *consumer,
  ApolloCoreCaptureCodec codec,
  std::uint64_t source_sequence_number,
  std::uint64_t source_display_time,
  bool has_output_callback_latency_milliseconds,
  double output_callback_latency_milliseconds,
  bool is_key_frame,
  bool is_hdr_signaled,
  const std::uint8_t *payload_bytes,
  std::size_t payload_size
) {
  if (!consumer) {
    return;
  }

  encoded_frame_state_t frame {};
  frame.codec = codec;
  frame.source_sequence_number = source_sequence_number;
  frame.source_display_time = source_display_time;
  frame.has_output_callback_latency_milliseconds = has_output_callback_latency_milliseconds;
  frame.output_callback_latency_milliseconds = output_callback_latency_milliseconds;
  frame.is_key_frame = is_key_frame;
  frame.is_hdr_signaled = is_hdr_signaled;

  if (payload_bytes && payload_size > 0) {
    frame.payload.assign(payload_bytes, payload_bytes + payload_size);
  }

  std::scoped_lock lock(consumer->mutex);
  consumer->frame_count += 1;
  consumer->last_frame = std::move(frame);
}

void ApolloCoreEncodedCaptureConsumerConsumeEvent(
  ApolloCoreEncodedCaptureConsumer *consumer,
  ApolloCoreCaptureEventKind kind,
  const char *message,
  bool has_stop_status,
  std::int32_t stop_status,
  bool has_automatic_restart_count,
  std::uint64_t automatic_restart_count,
  bool has_source_display_time,
  std::uint64_t source_display_time
) {
  if (!consumer) {
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

  std::scoped_lock lock(consumer->mutex);
  consumer->event_count += 1;
  consumer->last_event = std::move(event);
}

ApolloCoreEncodedCaptureConsumerSnapshot ApolloCoreEncodedCaptureConsumerCopySnapshot(
  const ApolloCoreEncodedCaptureConsumer *consumer
) {
  ApolloCoreEncodedCaptureConsumerSnapshot snapshot {};
  snapshot.last_frame_codec = ApolloCoreCaptureCodecUnknown;
  snapshot.last_event_kind = ApolloCoreCaptureEventKindUnknown;

  if (!consumer) {
    return snapshot;
  }

  std::scoped_lock lock(consumer->mutex);
  snapshot.frame_count = consumer->frame_count;
  snapshot.event_count = consumer->event_count;

  if (consumer->last_frame.has_value()) {
    const auto &frame = *consumer->last_frame;
    snapshot.has_last_frame = true;
    snapshot.last_frame_codec = frame.codec;
    snapshot.last_frame_payload_size = frame.payload.size();
    snapshot.last_frame_source_sequence_number = frame.source_sequence_number;
    snapshot.last_frame_source_display_time = frame.source_display_time;
    snapshot.last_frame_is_key_frame = frame.is_key_frame;
    snapshot.last_frame_is_hdr_signaled = frame.is_hdr_signaled;
  }

  if (consumer->last_event.has_value()) {
    const auto &event = *consumer->last_event;
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

size_t ApolloCoreEncodedCaptureConsumerCopyLastFramePayload(
  const ApolloCoreEncodedCaptureConsumer *consumer,
  std::uint8_t *destination,
  size_t capacity
) {
  if (!consumer) {
    return 0;
  }

  std::scoped_lock lock(consumer->mutex);
  if (!consumer->last_frame.has_value()) {
    return 0;
  }

  const auto &payload = consumer->last_frame->payload;
  const auto copy_size = std::min(capacity, payload.size());
  if (copy_size > 0 && destination) {
    std::memcpy(destination, payload.data(), copy_size);
  }
  return copy_size;
}

size_t ApolloCoreEncodedCaptureConsumerCopyLastEventMessage(
  const ApolloCoreEncodedCaptureConsumer *consumer,
  char *destination,
  size_t capacity
) {
  if (!consumer) {
    return 0;
  }

  std::scoped_lock lock(consumer->mutex);
  if (!consumer->last_event.has_value()) {
    return 0;
  }

  const auto &message = consumer->last_event->message;
  const auto copy_size = std::min(capacity, message.size());
  if (copy_size > 0 && destination) {
    std::memcpy(destination, message.data(), copy_size);
  }
  return copy_size;
}
