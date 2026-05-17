/**
 * @file src/platform/windows/lumen_protocol_adapter.h
 * @brief Windows capture signal adapter for the source-neutral Lumen protocol.
 */
#pragma once

#include "src/lumen_protocol.h"
#include "src/lumen_protocol_adapter.h"

#include <algorithm>
#include <cstdint>

namespace lumen::platform::windows {
  enum class capture_backend {
    dxgi,
    wgc,
  };

  enum class encoder_backend {
    unknown,
    nvenc_h264,
    nvenc_hevc_main10,
    nvenc_av1_main10,
  };

  struct source_signal {
    bool hdr_enabled = false;
    capture_backend capture_backend = capture_backend::dxgi;
    encoder_backend encoder = encoder_backend::unknown;
    std::uint32_t dirty_region_count = 1;
    std::uint32_t encoded_lane_count = 1;
  };

  struct capture_signal {
    protocol::dynamic_range_transport requested_transport = protocol::dynamic_range_transport::sdr;
    protocol::sink_capability sink;
    source_signal source;
  };

  [[nodiscard]] constexpr bool encoder_supports_hdr_overlay(const encoder_backend encoder) {
    switch (encoder) {
      case encoder_backend::nvenc_hevc_main10:
      case encoder_backend::nvenc_av1_main10:
        return true;
      case encoder_backend::unknown:
      case encoder_backend::nvenc_h264:
      default:
        return false;
    }
  }

  [[nodiscard]] constexpr protocol::encoded_tile_layout source_encoded_tile_layout(
    const source_signal &source
  ) {
    return {
      .tile_count = std::max<std::uint32_t>(source.dirty_region_count, 1),
      .encoded_lane_count = std::max<std::uint32_t>(source.encoded_lane_count, 1),
    };
  }

  [[nodiscard]] constexpr protocol::dynamic_range_transport negotiated_transport(
    const capture_signal &signal
  ) {
    if (signal.requested_transport == protocol::dynamic_range_transport::sdr ||
        !signal.source.hdr_enabled ||
        !signal.sink.prefers_hdr) {
      return protocol::dynamic_range_transport::sdr;
    }

    if (signal.requested_transport == protocol::dynamic_range_transport::sdr_base_hdr_overlay) {
      if (!encoder_supports_hdr_overlay(signal.source.encoder)) {
        return protocol::dynamic_range_transport::sdr;
      }

      if (signal.sink.supports_hdr_tile_overlay &&
          signal.sink.supports_per_frame_hdr_metadata &&
          signal.sink.supports_encoded_tile_stream &&
          !source_encoded_tile_layout(signal.source).is_single_frame()) {
        return protocol::dynamic_range_transport::sdr_base_hdr_overlay;
      }
      if (signal.sink.supports_per_frame_hdr_metadata) {
        return protocol::dynamic_range_transport::frame_gated_hdr;
      }
      return protocol::dynamic_range_transport::sdr;
    }

    if (signal.requested_transport == protocol::dynamic_range_transport::frame_gated_hdr) {
      return signal.sink.supports_per_frame_hdr_metadata ?
               protocol::dynamic_range_transport::frame_gated_hdr :
               protocol::dynamic_range_transport::sdr;
    }

    if (signal.requested_transport == protocol::dynamic_range_transport::full_frame_hdr) {
      return encoder_supports_hdr_overlay(signal.source.encoder) ?
               protocol::dynamic_range_transport::full_frame_hdr :
               protocol::dynamic_range_transport::sdr;
    }

    return protocol::dynamic_range_transport::sdr;
  }

  [[nodiscard]] constexpr video::lumen_protocol_adapter_t make_lumen_protocol_adapter(
    const capture_signal &signal
  ) {
    const auto layout = source_encoded_tile_layout(signal.source);
    const auto negotiated = negotiated_transport(signal);
    const auto presentation_signal = protocol::presentation_signal {
      .requested_transport = signal.requested_transport,
      .negotiated_transport = negotiated,
      .sink = signal.sink,
      .source_layout = layout,
    };

    return {
      .requested_transport = signal.requested_transport,
      .negotiated_transport = negotiated,
      .sink_capability = signal.sink,
      .source_layout = layout,
      .presentation_contract = protocol::resolve_presentation_contract(presentation_signal),
    };
  }
}  // namespace lumen::platform::windows
