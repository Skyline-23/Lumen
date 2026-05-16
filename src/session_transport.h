/**
 * @file src/session_transport.h
 * @brief Shared sink capability and transport request types.
 */
#pragma once

#include "lumen_protocol.h"

#include <algorithm>
#include <cstdlib>
#include <string>
#include <string_view>

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
    bool supports_encoded_tile_stream = false;
  };

  struct sink_request_t {
    sink_mode_t mode;
    sink_capability_t capability;
    dynamic_range_transport_e dynamic_range_transport = dynamic_range_transport_e::unknown;
  };

  inline bool partial_hdr_overlay_producer_available() {
    return true;
  }

  [[nodiscard]] constexpr std::string_view lumen_protocol_client_sink_gamut_name(const int gamut) {
    switch (static_cast<client_sink_gamut_e>(gamut)) {
      case client_sink_gamut_e::srgb:
        return "srgb";
      case client_sink_gamut_e::display_p3:
        return "display-p3";
      case client_sink_gamut_e::rec2020:
        return "rec2020";
      case client_sink_gamut_e::unknown:
      default:
        return "unknown";
    }
  }

  [[nodiscard]] constexpr std::string_view lumen_protocol_client_sink_transfer_name(const int transfer) {
    switch (static_cast<client_sink_transfer_e>(transfer)) {
      case client_sink_transfer_e::sdr:
        return "sdr";
      case client_sink_transfer_e::pq:
        return "pq";
      case client_sink_transfer_e::hlg:
        return "hlg";
      case client_sink_transfer_e::unknown:
      default:
        return "unknown";
    }
  }

  [[nodiscard]] constexpr std::string_view lumen_protocol_dynamic_range_transport_name(
    const dynamic_range_transport_e transport
  ) {
    switch (transport) {
      case dynamic_range_transport_e::sdr:
        return "sdr";
      case dynamic_range_transport_e::full_frame_hdr:
        return "full-frame-hdr";
      case dynamic_range_transport_e::frame_gated_hdr:
        return "frame-gated-hdr";
      case dynamic_range_transport_e::sdr_base_hdr_overlay:
        return "sdr-base-hdr-overlay";
      case dynamic_range_transport_e::unknown:
      default:
        return "unknown";
    }
  }

  [[nodiscard]] constexpr std::string_view lumen_protocol_dynamic_range_transport_name(const int transport) {
    return lumen_protocol_dynamic_range_transport_name(
      static_cast<dynamic_range_transport_e>(transport)
    );
  }

  inline int parse_lumen_protocol_client_sink_gamut(const std::string_view value) {
    if (value == "display-p3" || value == "display_p3" || value == "p3") {
      return static_cast<int>(client_sink_gamut_e::display_p3);
    }
    if (value == "rec2020" || value == "bt2020" || value == "2020") {
      return static_cast<int>(client_sink_gamut_e::rec2020);
    }
    if (value == "srgb" || value == "rec709" || value == "709") {
      return static_cast<int>(client_sink_gamut_e::srgb);
    }
    return static_cast<int>(client_sink_gamut_e::unknown);
  }

  inline int parse_lumen_protocol_client_sink_transfer(const std::string_view value) {
    if (value == "pq" || value == "hdr-pq" || value == "st2084" || value == "smpte2084") {
      return static_cast<int>(client_sink_transfer_e::pq);
    }
    if (value == "hlg" || value == "hdr-hlg") {
      return static_cast<int>(client_sink_transfer_e::hlg);
    }
    if (value == "sdr" || value == "gamma") {
      return static_cast<int>(client_sink_transfer_e::sdr);
    }
    return static_cast<int>(client_sink_transfer_e::unknown);
  }

  inline dynamic_range_transport_e parse_lumen_protocol_dynamic_range_transport(const std::string_view value) {
    if (value == "sdr") {
      return dynamic_range_transport_e::sdr;
    }
    if (value == "full-frame-hdr" || value == "full_frame_hdr") {
      return dynamic_range_transport_e::full_frame_hdr;
    }
    if (value == "frame-gated-hdr" || value == "frame_gated_hdr") {
      return dynamic_range_transport_e::frame_gated_hdr;
    }
    if (value == "sdr-base-hdr-overlay" || value == "sdr_base_hdr_overlay") {
      return dynamic_range_transport_e::sdr_base_hdr_overlay;
    }
    return dynamic_range_transport_e::sdr;
  }

  inline float parse_lumen_protocol_headroom(const std::string_view value) {
    if (value.empty()) {
      return 0.0f;
    }

    std::string buffer {value};
    char *end_ptr = nullptr;
    const auto parsed = std::strtof(buffer.c_str(), &end_ptr);
    if (end_ptr == buffer.c_str() || (end_ptr != nullptr && *end_ptr != '\0')) {
      return 0.0f;
    }

    return std::max(parsed, 0.0f);
  }

  inline int parse_lumen_protocol_peak_luminance_nits(const std::string_view value) {
    if (value.empty()) {
      return 0;
    }

    std::string buffer {value};
    char *end_ptr = nullptr;
    const auto parsed = std::strtol(buffer.c_str(), &end_ptr, 10);
    if (end_ptr == buffer.c_str() || (end_ptr != nullptr && *end_ptr != '\0')) {
      return 0;
    }

    return static_cast<int>(std::max<long>(parsed, 0l));
  }

  inline bool client_sink_transfer_prefers_hdr(const int transfer) {
    const auto normalized_transfer = static_cast<client_sink_transfer_e>(transfer);
    return normalized_transfer == client_sink_transfer_e::pq ||
           normalized_transfer == client_sink_transfer_e::hlg;
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
    const auto sink_prefers_hdr = client_sink_transfer_prefers_hdr(request.capability.transfer);

    switch (effective_dynamic_range_transport(request.dynamic_range_transport)) {
      case dynamic_range_transport_e::full_frame_hdr:
        if (!sink_prefers_hdr) {
          return dynamic_range_transport_e::sdr;
        }
        return dynamic_range_transport_e::full_frame_hdr;
      case dynamic_range_transport_e::frame_gated_hdr:
        if (!sink_prefers_hdr) {
          return dynamic_range_transport_e::sdr;
        }
        return request.capability.supports_frame_gated_hdr ?
                 dynamic_range_transport_e::frame_gated_hdr :
                 dynamic_range_transport_e::sdr;
      case dynamic_range_transport_e::sdr_base_hdr_overlay:
        if (!sink_prefers_hdr) {
          return dynamic_range_transport_e::sdr;
        }
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

  inline lumen::protocol::dynamic_range_transport to_lumen_protocol_transport(
    const dynamic_range_transport_e transport
  ) {
    switch (effective_dynamic_range_transport(transport)) {
      case dynamic_range_transport_e::full_frame_hdr:
        return lumen::protocol::dynamic_range_transport::full_frame_hdr;
      case dynamic_range_transport_e::frame_gated_hdr:
        return lumen::protocol::dynamic_range_transport::frame_gated_hdr;
      case dynamic_range_transport_e::sdr_base_hdr_overlay:
        return lumen::protocol::dynamic_range_transport::sdr_base_hdr_overlay;
      case dynamic_range_transport_e::sdr:
      case dynamic_range_transport_e::unknown:
      default:
        return lumen::protocol::dynamic_range_transport::sdr;
    }
  }

  inline lumen::protocol::sink_capability to_lumen_protocol_sink_capability(
    const sink_capability_t &capability
  ) {
    return {
      .prefers_hdr = client_sink_transfer_prefers_hdr(capability.transfer),
      .supports_hdr_tile_overlay = capability.supports_hdr_tile_overlay,
      .supports_per_frame_hdr_metadata = capability.supports_per_frame_hdr_metadata,
      .supports_encoded_tile_stream = capability.supports_encoded_tile_stream,
    };
  }

  struct lumen_protocol_adapter_t {
    lumen::protocol::dynamic_range_transport requested_transport =
      lumen::protocol::dynamic_range_transport::sdr;
    lumen::protocol::dynamic_range_transport negotiated_transport =
      lumen::protocol::dynamic_range_transport::sdr;
    lumen::protocol::sink_capability sink_capability;
    lumen::protocol::encoded_tile_layout source_layout;
    lumen::protocol::presentation_contract presentation_contract =
      lumen::protocol::presentation_contract::single_frame;

    [[nodiscard]] constexpr std::string_view presentation_contract_name() const {
      return lumen::protocol::presentation_contract_name(presentation_contract);
    }

    [[nodiscard]] constexpr std::string_view presentation_completion_name() const {
      return lumen::protocol::presentation_completion_rule_name(
        lumen::protocol::completion_rule_for(presentation_contract)
      );
    }
  };

  inline lumen_protocol_adapter_t make_lumen_protocol_adapter(
    const sink_request_t &request,
    const lumen::protocol::encoded_tile_layout source_layout
  ) {
    const auto requested_transport =
      to_lumen_protocol_transport(request.dynamic_range_transport);
    const auto negotiated_transport =
      to_lumen_protocol_transport(effective_dynamic_range_transport(request));
    const auto sink_capability =
      to_lumen_protocol_sink_capability(request.capability);
    const auto presentation_contract =
      lumen::protocol::resolve_presentation_contract(
        {
          .requested_transport = negotiated_transport,
          .sink = sink_capability,
          .source_layout = source_layout,
        }
      );

    return {
      .requested_transport = requested_transport,
      .negotiated_transport = negotiated_transport,
      .sink_capability = sink_capability,
      .source_layout = source_layout,
      .presentation_contract = presentation_contract,
    };
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
