/**
 * @file src/session_transport.h
 * @brief Shared sink capability and transport request types.
 */
#pragma once

namespace video {
  enum class client_sink_gamut_e : int {
    unknown = 0,
    srgb = 1,
    display_p3 = 2,
    rec2020 = 3,
  };

  enum class client_sink_transfer_e : int {
    unknown = 0,
    sdr = 1,
    pq = 2,
    hlg = 3,
  };

  enum class dynamic_range_transport_e : int {
    unknown = 0,
    sdr = 1,
    full_frame_hdr = 2,
    frame_gated_hdr = 3,
    sdr_base_hdr_overlay = 4,
  };

  struct sink_mode_t {
    bool hidpi = false;
    bool scale_explicit = false;
    bool mode_is_logical = false;
    int scale_percent = 100;
  };

  struct sink_capability_t {
    int gamut = static_cast<int>(client_sink_gamut_e::unknown);
    int transfer = static_cast<int>(client_sink_transfer_e::unknown);
    float current_edr_headroom = 0.0f;
    float potential_edr_headroom = 0.0f;
    int current_peak_luminance_nits = 0;
    int potential_peak_luminance_nits = 0;
    bool supports_frame_gated_hdr = false;
    bool supports_hdr_tile_overlay = false;
    bool supports_per_frame_hdr_metadata = false;
  };

  struct sink_request_t {
    sink_mode_t mode;
    sink_capability_t capability;
    dynamic_range_transport_e dynamic_range_transport = dynamic_range_transport_e::unknown;
  };

  inline bool partial_hdr_overlay_producer_available() {
    return true;
  }

  inline dynamic_range_transport_e effective_dynamic_range_transport(const dynamic_range_transport_e requested_transport) {
    switch (requested_transport) {
      case dynamic_range_transport_e::sdr:
      case dynamic_range_transport_e::full_frame_hdr:
      case dynamic_range_transport_e::frame_gated_hdr:
      case dynamic_range_transport_e::sdr_base_hdr_overlay:
        return requested_transport;
      case dynamic_range_transport_e::unknown:
      default:
        return dynamic_range_transport_e::sdr;
    }
  }

  inline dynamic_range_transport_e effective_dynamic_range_transport(const int requested_transport) {
    return effective_dynamic_range_transport(static_cast<dynamic_range_transport_e>(requested_transport));
  }

  inline dynamic_range_transport_e effective_dynamic_range_transport(const sink_request_t &request) {
    switch (effective_dynamic_range_transport(request.dynamic_range_transport)) {
      case dynamic_range_transport_e::full_frame_hdr:
        return dynamic_range_transport_e::full_frame_hdr;
      case dynamic_range_transport_e::frame_gated_hdr:
        return request.capability.supports_frame_gated_hdr ?
                 dynamic_range_transport_e::frame_gated_hdr :
                 dynamic_range_transport_e::sdr;
      case dynamic_range_transport_e::sdr_base_hdr_overlay:
        if (partial_hdr_overlay_producer_available() &&
            request.capability.supports_hdr_tile_overlay &&
            request.capability.supports_per_frame_hdr_metadata) {
          return dynamic_range_transport_e::sdr_base_hdr_overlay;
        }
        if (request.capability.supports_frame_gated_hdr) {
          return dynamic_range_transport_e::frame_gated_hdr;
        }
        return dynamic_range_transport_e::sdr;
      case dynamic_range_transport_e::sdr:
      case dynamic_range_transport_e::unknown:
      default:
        return dynamic_range_transport_e::sdr;
    }
  }

  inline bool dynamic_range_transport_uses_hdr_stream(const dynamic_range_transport_e transport) {
    return transport == dynamic_range_transport_e::full_frame_hdr ||
           transport == dynamic_range_transport_e::frame_gated_hdr;
  }

  inline bool dynamic_range_transport_uses_hdr_frame_state(const dynamic_range_transport_e transport) {
    return transport == dynamic_range_transport_e::full_frame_hdr ||
           transport == dynamic_range_transport_e::frame_gated_hdr ||
           transport == dynamic_range_transport_e::sdr_base_hdr_overlay;
  }

  inline bool dynamic_range_transport_requires_hdr_display(const dynamic_range_transport_e transport) {
    return dynamic_range_transport_uses_hdr_frame_state(transport);
  }

  inline int effective_capture_frame_rate_for_workload(
    int requested_frame_rate,
    int width,
    int height,
    const dynamic_range_transport_e transport
  ) {
    const auto normalized_requested_frame_rate = requested_frame_rate > 0 ? requested_frame_rate : 60;
    return normalized_requested_frame_rate;
  }

  inline int effective_capture_frame_rate_millihz_for_workload(
    int requested_frame_rate_millihz,
    int width,
    int height,
    const dynamic_range_transport_e transport
  ) {
    const auto normalized_requested_frame_rate_millihz =
      requested_frame_rate_millihz > 0 ? requested_frame_rate_millihz : 60000;
    const auto requested_frame_rate =
      (normalized_requested_frame_rate_millihz + 999) / 1000;

    return effective_capture_frame_rate_for_workload(
             requested_frame_rate,
             width,
             height,
             transport
           ) *
           1000;
  }
}  // namespace video
