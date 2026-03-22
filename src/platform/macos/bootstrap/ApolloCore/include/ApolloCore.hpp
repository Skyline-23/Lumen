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

  class encoded_capture_ingress {
  public:
    encoded_capture_ingress();
    ~encoded_capture_ingress();

    encoded_capture_ingress(const encoded_capture_ingress &) = delete;
    encoded_capture_ingress &operator=(const encoded_capture_ingress &) = delete;

    encoded_capture_ingress(encoded_capture_ingress &&other) noexcept;
    encoded_capture_ingress &operator=(encoded_capture_ingress &&other) noexcept;

    void reset();
    void set_frame_capacity(std::size_t capacity);
    void set_event_capacity(std::size_t capacity);
    void consume_sample_buffer(
      ApolloCoreCaptureCodec codec,
      std::uint64_t source_sequence_number,
      std::uint64_t source_display_time,
      bool has_output_callback_latency_milliseconds,
      double output_callback_latency_milliseconds,
      bool is_key_frame,
      bool is_hdr_signaled,
      CMSampleBufferRef sample_buffer
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
    ApolloCoreEncodedCaptureIngressSnapshot snapshot() const;
    CMSampleBufferRef create_retained_last_sample_buffer() const;
    ApolloCoreEncodedCaptureFrameRecord pop_next_frame(CMSampleBufferRef *sample_buffer_out);
    ApolloCoreEncodedCaptureEventRecord pop_next_event(char *message_destination, std::size_t message_capacity);
    std::string copy_last_event_message() const;
    ApolloCoreEncodedCaptureIngress *handle() const;

  private:
    ApolloCoreEncodedCaptureIngress *handle_ = nullptr;
  };
}

#endif
