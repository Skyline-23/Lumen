/**
 * @file src/lumen_protocol_platform_adapter.h
 * @brief Shared platform adapter helpers for source-neutral Lumen presentation signals.
 */
#pragma once

#include "lumen_protocol.h"

namespace lumen::platform {
  struct protocol_source_signal {
    bool hdr_enabled = false;
    bool supports_hdr_overlay_encode = false;
    protocol::encoded_tile_layout source_layout;
  };

  struct protocol_negotiation_input {
    protocol::dynamic_range_transport requested_transport = protocol::dynamic_range_transport::sdr;
    protocol::sink_capability sink;
    protocol_source_signal source;
  };

  struct protocol_adapter_input {
    protocol::dynamic_range_transport requested_transport = protocol::dynamic_range_transport::sdr;
    protocol::dynamic_range_transport negotiated_transport = protocol::dynamic_range_transport::sdr;
    protocol::sink_capability sink;
    protocol::encoded_tile_layout source_layout;
  };

  struct protocol_adapter_output {
    protocol::dynamic_range_transport requested_transport = protocol::dynamic_range_transport::sdr;
    protocol::dynamic_range_transport negotiated_transport = protocol::dynamic_range_transport::sdr;
    protocol::sink_capability sink;
    protocol::encoded_tile_layout source_layout;
    protocol::presentation_contract presentation_contract = protocol::presentation_contract::single_frame;
  };

  [[nodiscard]] constexpr protocol::dynamic_range_transport negotiate_platform_transport(
    const protocol_negotiation_input &input
  ) {
    if (input.requested_transport == protocol::dynamic_range_transport::sdr ||
        !input.source.hdr_enabled ||
        !input.sink.prefers_hdr) {
      return protocol::dynamic_range_transport::sdr;
    }

    if (input.requested_transport == protocol::dynamic_range_transport::sdr_base_hdr_overlay) {
      if (!input.source.supports_hdr_overlay_encode) {
        return protocol::dynamic_range_transport::sdr;
      }

      if (input.sink.supports_hdr_tile_overlay &&
          input.sink.supports_per_frame_hdr_metadata &&
          input.sink.supports_encoded_tile_stream &&
          !input.source.source_layout.is_single_frame()) {
        return protocol::dynamic_range_transport::sdr_base_hdr_overlay;
      }
      if (input.sink.supports_per_frame_hdr_metadata) {
        return protocol::dynamic_range_transport::frame_gated_hdr;
      }
      return protocol::dynamic_range_transport::sdr;
    }

    if (input.requested_transport == protocol::dynamic_range_transport::frame_gated_hdr) {
      return input.sink.supports_per_frame_hdr_metadata ?
               protocol::dynamic_range_transport::frame_gated_hdr :
               protocol::dynamic_range_transport::sdr;
    }

    if (input.requested_transport == protocol::dynamic_range_transport::full_frame_hdr) {
      return input.source.supports_hdr_overlay_encode ?
               protocol::dynamic_range_transport::full_frame_hdr :
               protocol::dynamic_range_transport::sdr;
    }

    return protocol::dynamic_range_transport::sdr;
  }

  [[nodiscard]] constexpr protocol_adapter_input make_protocol_adapter_input(
    const protocol_negotiation_input &input
  ) {
    return {
      .requested_transport = input.requested_transport,
      .negotiated_transport = negotiate_platform_transport(input),
      .sink = input.sink,
      .source_layout = input.source.source_layout,
    };
  }

  [[nodiscard]] constexpr protocol_adapter_output resolve_protocol_adapter(
    const protocol_adapter_input &input
  ) {
    const auto presentation_signal = protocol::presentation_signal {
      .requested_transport = input.requested_transport,
      .negotiated_transport = input.negotiated_transport,
      .sink = input.sink,
      .source_layout = input.source_layout,
    };

    return {
      .requested_transport = input.requested_transport,
      .negotiated_transport = input.negotiated_transport,
      .sink = input.sink,
      .source_layout = input.source_layout,
      .presentation_contract = protocol::resolve_presentation_contract(presentation_signal),
    };
  }
}  // namespace lumen::platform
