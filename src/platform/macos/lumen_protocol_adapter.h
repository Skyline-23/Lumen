/**
 * @file src/platform/macos/lumen_protocol_adapter.h
 * @brief macOS capture signal adapter for the source-neutral Lumen protocol.
 */
#pragma once

#include "src/lumen_protocol_adapter.h"
#include "src/lumen_protocol_platform_adapter.h"

#include <algorithm>
#include <cstdint>

namespace lumen::platform::macos {
  enum class capture_backend {
    core_display,
    screen_capture_kit,
  };

  enum class encoder_backend {
    unknown,
    videotoolbox_h264,
    videotoolbox_hevc_main10,
    videotoolbox_av1_main10,
    videotoolbox_prores_422_hq,
  };

  struct source_signal {
    bool hdr_enabled = false;
    capture_backend capture_backend = capture_backend::core_display;
    encoder_backend encoder = encoder_backend::unknown;
    std::uint32_t tile_count = 1;
    std::uint32_t encoded_lane_count = 1;
  };

  struct capture_signal {
    protocol::dynamic_range_transport requested_transport = protocol::dynamic_range_transport::sdr;
    protocol::sink_capability sink;
    source_signal source;
  };

  [[nodiscard]] constexpr bool encoder_supports_hdr_overlay(const encoder_backend encoder) {
    switch (encoder) {
      case encoder_backend::videotoolbox_hevc_main10:
      case encoder_backend::videotoolbox_av1_main10:
      case encoder_backend::videotoolbox_prores_422_hq:
        return true;
      case encoder_backend::unknown:
      case encoder_backend::videotoolbox_h264:
      default:
        return false;
    }
  }

  [[nodiscard]] constexpr protocol::encoded_tile_layout source_encoded_tile_layout(
    const source_signal &source
  ) {
    return {
      .tile_count = std::max<std::uint32_t>(source.tile_count, 1),
      .encoded_lane_count = std::max<std::uint32_t>(source.encoded_lane_count, 1),
    };
  }

  [[nodiscard]] constexpr platform::protocol_adapter_input make_protocol_adapter_input(
    const capture_signal &signal
  ) {
    return platform::make_protocol_adapter_input(
      platform::protocol_negotiation_input {
        .requested_transport = signal.requested_transport,
        .sink = signal.sink,
        .source = {
          .hdr_enabled = signal.source.hdr_enabled,
          .supports_hdr_overlay_encode = encoder_supports_hdr_overlay(signal.source.encoder),
          .source_layout = source_encoded_tile_layout(signal.source),
        },
      }
    );
  }

  [[nodiscard]] constexpr video::lumen_protocol_adapter_t make_lumen_protocol_adapter(
    const capture_signal &signal
  ) {
    return video::make_lumen_protocol_adapter(
      platform::resolve_protocol_adapter(make_protocol_adapter_input(signal))
    );
  }
}  // namespace lumen::platform::macos
