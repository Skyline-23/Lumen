#ifndef LUMEN_CORE_INTERNAL_HPP
#define LUMEN_CORE_INTERNAL_HPP

#include "LumenCore.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace lumen::core {
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
      LumenCoreCaptureCodec codec,
      std::uint64_t source_sequence_number,
      std::uint64_t source_display_time,
      bool has_output_callback_latency_milliseconds,
      double output_callback_latency_milliseconds,
      bool is_key_frame,
      bool is_hdr_signaled,
      bool is_replay,
      CMSampleBufferRef sample_buffer
    );
    void consume_event(
      LumenCoreCaptureEventKind kind,
      const char *message,
      bool has_stop_status,
      std::int32_t stop_status,
      bool has_automatic_restart_count,
      std::uint64_t automatic_restart_count,
      bool has_source_display_time,
      std::uint64_t source_display_time
    );
    LumenCoreEncodedCaptureIngressSnapshot snapshot() const;
    CMSampleBufferRef create_retained_last_sample_buffer() const;
    LumenCoreEncodedCaptureFrameRecord pop_next_frame(CMSampleBufferRef *sample_buffer_out);
    LumenCoreEncodedCaptureEventRecord pop_next_event(char *message_destination, std::size_t message_capacity);
    std::string copy_last_event_message() const;
    LumenCoreEncodedCaptureIngress *handle() const;

  private:
    LumenCoreEncodedCaptureIngress *handle_ = nullptr;
  };
}

#endif
