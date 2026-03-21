#ifndef APOLLO_CORE_HPP
#define APOLLO_CORE_HPP

#include "ApolloCore.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace apollo::core {
  std::string version_string();
  std::string runtime_description();

  class encoded_capture_consumer {
  public:
    encoded_capture_consumer();
    ~encoded_capture_consumer();

    encoded_capture_consumer(const encoded_capture_consumer &) = delete;
    encoded_capture_consumer &operator=(const encoded_capture_consumer &) = delete;

    encoded_capture_consumer(encoded_capture_consumer &&other) noexcept;
    encoded_capture_consumer &operator=(encoded_capture_consumer &&other) noexcept;

    void reset();
    void consume_frame(
      ApolloCoreCaptureCodec codec,
      std::uint64_t source_sequence_number,
      std::uint64_t source_display_time,
      bool has_output_callback_latency_milliseconds,
      double output_callback_latency_milliseconds,
      bool is_key_frame,
      bool is_hdr_signaled,
      const std::uint8_t *payload_bytes,
      std::size_t payload_size
    );
    void consume_event(
      ApolloCoreCaptureEventKind kind,
      const char *message,
      bool has_stop_status,
      std::int32_t stop_status,
      bool has_automatic_restart_count,
      std::uint64_t automatic_restart_count,
      bool has_source_display_time,
      std::uint64_t source_display_time
    );
    ApolloCoreEncodedCaptureConsumerSnapshot snapshot() const;
    std::vector<std::uint8_t> copy_last_frame_payload() const;
    std::string copy_last_event_message() const;
    ApolloCoreEncodedCaptureConsumer *handle() const;

  private:
    ApolloCoreEncodedCaptureConsumer *handle_ = nullptr;
  };
}

#endif
