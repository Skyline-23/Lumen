/**
 * @file src/lumen_protocol_adapter.h
 * @brief Lumen protocol adapters for normalized video transport state.
 */
#pragma once

#include "lumen_protocol.h"
#include "session_transport.h"

#include <algorithm>
#include <cstdlib>
#include <string>
#include <string_view>

namespace video {
  struct lumen_sink_request_fields_t {
    bool scale_explicit = false;
    bool mode_is_logical = false;
    int scale_percent = 100;
    bool hidpi = false;
    std::string_view gamut;
    std::string_view transfer;
    std::string_view current_edr_headroom;
    std::string_view potential_edr_headroom;
    std::string_view current_peak_luminance_nits;
    std::string_view potential_peak_luminance_nits;
    std::string_view requested_dynamic_range_transport;
    bool supports_frame_gated_hdr = false;
    bool supports_hdr_tile_overlay = false;
    bool supports_per_frame_hdr_metadata = false;
    bool supports_encoded_tile_stream = false;
  };

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

  inline sink_request_t make_lumen_sink_request(const lumen_sink_request_fields_t &fields) {
    return {
      .mode = {
        .hidpi = fields.hidpi,
        .scale_explicit = fields.scale_explicit,
        .mode_is_logical = fields.mode_is_logical,
        .scale_percent = fields.scale_percent,
      },
      .capability = {
        .gamut = parse_lumen_protocol_client_sink_gamut(fields.gamut),
        .transfer = parse_lumen_protocol_client_sink_transfer(fields.transfer),
        .current_edr_headroom = parse_lumen_protocol_headroom(fields.current_edr_headroom),
        .potential_edr_headroom = parse_lumen_protocol_headroom(fields.potential_edr_headroom),
        .current_peak_luminance_nits = parse_lumen_protocol_peak_luminance_nits(fields.current_peak_luminance_nits),
        .potential_peak_luminance_nits = parse_lumen_protocol_peak_luminance_nits(fields.potential_peak_luminance_nits),
        .supports_frame_gated_hdr = fields.supports_frame_gated_hdr,
        .supports_hdr_tile_overlay = fields.supports_hdr_tile_overlay,
        .supports_per_frame_hdr_metadata = fields.supports_per_frame_hdr_metadata,
        .supports_encoded_tile_stream = fields.supports_encoded_tile_stream,
      },
      .dynamic_range_transport = parse_lumen_protocol_dynamic_range_transport(fields.requested_dynamic_range_transport),
    };
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

    [[nodiscard]] constexpr lumen::protocol::presentation_signal presentation_signal() const {
      return {
        .requested_transport = requested_transport,
        .negotiated_transport = negotiated_transport,
        .sink = sink_capability,
        .source_layout = source_layout,
      };
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
        lumen::protocol::presentation_signal {
          .requested_transport = requested_transport,
          .negotiated_transport = negotiated_transport,
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
}  // namespace video
