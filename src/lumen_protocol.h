/**
 * @file src/lumen_protocol.h
 * @brief Source-neutral Lumen streaming protocol constants.
 */
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string_view>

#include "lumen_protocol_control_wire_generated.h"

namespace lumen::protocol {
  enum class dynamic_range_transport {
    sdr,
    full_frame_hdr,
    frame_gated_hdr,
    sdr_base_hdr_overlay,
  };

  struct sink_capability {
    bool prefers_hdr = false;
    bool supports_hdr_tile_overlay = false;
    bool supports_per_frame_hdr_metadata = false;
    bool supports_encoded_tile_stream = false;
  };

  struct encoded_tile_layout {
    std::uint32_t tile_count = 1;
    std::uint32_t encoded_lane_count = 1;

    [[nodiscard]] constexpr bool is_single_frame() const {
      return tile_count <= 1 && encoded_lane_count <= 1;
    }
  };

  enum class presentation_completion_rule {
    full_frame,
    per_tile_after_lane_prime,
  };

  enum class presentation_contract {
    single_frame,
    primed_per_tile_update,
  };

  struct presentation_input {
    dynamic_range_transport requested_transport = dynamic_range_transport::sdr;
    sink_capability sink;
    encoded_tile_layout source_layout;
  };

  [[nodiscard]] constexpr presentation_contract resolve_presentation_contract(
    const presentation_input &input
  ) {
    if (input.requested_transport == dynamic_range_transport::sdr_base_hdr_overlay &&
        input.sink.prefers_hdr &&
        input.sink.supports_hdr_tile_overlay &&
        input.sink.supports_per_frame_hdr_metadata &&
        input.sink.supports_encoded_tile_stream &&
        !input.source_layout.is_single_frame()) {
      return presentation_contract::primed_per_tile_update;
    }

    return presentation_contract::single_frame;
  }

  [[nodiscard]] constexpr presentation_completion_rule completion_rule_for(
    const presentation_contract contract
  ) {
    switch (contract) {
      case presentation_contract::primed_per_tile_update:
        return presentation_completion_rule::per_tile_after_lane_prime;
      case presentation_contract::single_frame:
      default:
        return presentation_completion_rule::full_frame;
    }
  }

  namespace rtsp {
    using namespace std::literals;

    inline constexpr std::string_view video_bitstream_format = "x-shadow-video[0].bitStreamFormat"sv;
    inline constexpr std::string_view sink_scale_percent = "x-shadow-sink.scalePercent"sv;
    inline constexpr std::string_view sink_hidpi = "x-shadow-sink.hidpi"sv;
    inline constexpr std::string_view sink_mode_is_logical = "x-shadow-sink.modeIsLogical"sv;
    inline constexpr std::string_view sink_gamut = "x-shadow-sink.gamut"sv;
    inline constexpr std::string_view sink_transfer = "x-shadow-sink.transfer"sv;
    inline constexpr std::string_view sink_current_edr_headroom = "x-shadow-sink.currentEDRHeadroom"sv;
    inline constexpr std::string_view sink_potential_edr_headroom = "x-shadow-sink.potentialEDRHeadroom"sv;
    inline constexpr std::string_view sink_current_peak_luminance_nits = "x-shadow-sink.currentPeakLuminanceNits"sv;
    inline constexpr std::string_view sink_potential_peak_luminance_nits = "x-shadow-sink.potentialPeakLuminanceNits"sv;
    inline constexpr std::string_view sink_requested_dynamic_range_transport = "x-shadow-sink.requestedDynamicRangeTransport"sv;
    inline constexpr std::string_view sink_supports_frame_gated_hdr = "x-shadow-sink.supportsFrameGatedHDR"sv;
    inline constexpr std::string_view sink_supports_hdr_tile_overlay = "x-shadow-sink.supportsHDRTileOverlay"sv;
    inline constexpr std::string_view sink_supports_per_frame_hdr_metadata = "x-shadow-sink.supportsPerFrameHDRMetadata"sv;
    inline constexpr std::string_view sink_supports_encoded_tile_stream = "x-shadow-sink.supportsEncodedTileStream"sv;

    inline constexpr std::array required_announce_fields {
      video_bitstream_format,
      sink_scale_percent,
      sink_hidpi,
      sink_mode_is_logical,
      sink_gamut,
      sink_transfer,
      sink_current_edr_headroom,
      sink_potential_edr_headroom,
      sink_current_peak_luminance_nits,
      sink_potential_peak_luminance_nits,
      sink_requested_dynamic_range_transport,
      sink_supports_frame_gated_hdr,
      sink_supports_hdr_tile_overlay,
      sink_supports_per_frame_hdr_metadata,
    };
  }

  namespace launch {
    using namespace std::literals;

    inline constexpr std::string_view sink_scale_percent = "clientSinkScalePercent"sv;
    inline constexpr std::string_view sink_hidpi = "clientSinkHiDPI"sv;
    inline constexpr std::string_view sink_mode_is_logical = "clientSinkModeIsLogical"sv;
    inline constexpr std::string_view sink_gamut = "clientSinkGamut"sv;
    inline constexpr std::string_view sink_transfer = "clientSinkTransfer"sv;
    inline constexpr std::string_view sink_current_edr_headroom = "clientSinkCurrentEDRHeadroom"sv;
    inline constexpr std::string_view sink_potential_edr_headroom = "clientSinkPotentialEDRHeadroom"sv;
    inline constexpr std::string_view sink_current_peak_luminance_nits = "clientSinkCurrentPeakLuminanceNits"sv;
    inline constexpr std::string_view sink_potential_peak_luminance_nits = "clientSinkPotentialPeakLuminanceNits"sv;
    inline constexpr std::string_view requested_dynamic_range_transport = "requestedDynamicRangeTransport"sv;
    inline constexpr std::string_view sink_supports_frame_gated_hdr = "clientSinkSupportsFrameGatedHDR"sv;
    inline constexpr std::string_view sink_supports_hdr_tile_overlay = "clientSinkSupportsHDRTileOverlay"sv;
    inline constexpr std::string_view sink_supports_per_frame_hdr_metadata = "clientSinkSupportsPerFrameHDRMetadata"sv;
    inline constexpr std::string_view sink_supports_encoded_tile_stream = "clientSinkSupportsEncodedTileStream"sv;

    inline constexpr std::array required_launch_args {
      sink_scale_percent,
      sink_hidpi,
      sink_mode_is_logical,
      sink_gamut,
      sink_transfer,
      sink_current_edr_headroom,
      sink_potential_edr_headroom,
      sink_current_peak_luminance_nits,
      sink_potential_peak_luminance_nits,
      requested_dynamic_range_transport,
      sink_supports_frame_gated_hdr,
      sink_supports_hdr_tile_overlay,
      sink_supports_per_frame_hdr_metadata,
    };
  }

  namespace control {
    enum packet_index : std::size_t {
      start_a = 0,
      start_b = 1,
      invalidate_reference_frames = 2,
      loss_stats = 3,
      frame_stats = 4,
      input_data = 5,
      rumble_data = 6,
      termination = 7,
      periodic_ping = 8,
      request_idr_frame = 9,
      encrypted = 10,
      retired_hdr_mode = 11,
      rumble_trigger_data = 12,
      set_motion_event = 13,
      set_rgb_led = 14,
      execute_server_command = 15,
      set_clipboard = 16,
      file_transfer_nonce_request = 17,
      set_adaptive_triggers = 18,
      hdr_frame_state = 19,
      encoded_tile_frame_state = 20,
    };

    inline constexpr std::uint16_t execute_server_command_type = 0x3000;
    inline constexpr std::uint16_t set_clipboard_type = 0x3001;
    inline constexpr std::uint16_t file_transfer_nonce_request_type = 0x3002;
    inline constexpr std::array<std::uint16_t, 21> packet_types {
      0x0305,
      0x0307,
      0x0301,
      0x0201,
      0x0204,
      0x0206,
      0x010b,
      0x0109,
      0x0200,
      0x0302,
      0x0001,
      0x010e,
      0x5500,
      0x5501,
      0x5502,
      execute_server_command_type,
      set_clipboard_type,
      file_transfer_nonce_request_type,
      0x5503,
      hdr_frame_state_type,
      encoded_tile_frame_state_type,
    };

  }

  namespace presentation {
    using namespace std::literals;

    inline constexpr std::string_view single_frame = "single-frame"sv;
    inline constexpr std::string_view full_frame = "full-frame"sv;
    inline constexpr std::string_view primed_per_tile_update = "primed-per-tile-update"sv;
    inline constexpr std::string_view per_tile_after_lane_prime = "per-tile-after-lane-prime"sv;
  }

  [[nodiscard]] constexpr std::string_view presentation_contract_name(
    const presentation_contract contract
  ) {
    switch (contract) {
      case presentation_contract::primed_per_tile_update:
        return presentation::primed_per_tile_update;
      case presentation_contract::single_frame:
      default:
        return presentation::single_frame;
    }
  }

  [[nodiscard]] constexpr std::string_view presentation_completion_rule_name(
    const presentation_completion_rule rule
  ) {
    switch (rule) {
      case presentation_completion_rule::per_tile_after_lane_prime:
        return presentation::per_tile_after_lane_prime;
      case presentation_completion_rule::full_frame:
      default:
        return presentation::full_frame;
    }
  }
}
