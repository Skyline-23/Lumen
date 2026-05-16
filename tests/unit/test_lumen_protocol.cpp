/**
 * @file tests/unit/test_lumen_protocol.cpp
 * @brief Test Lumen protocol adapter contracts.
 */
#include <gtest/gtest.h>

#include <src/lumen_protocol_adapter.h>
#include <src/lumen_protocol.h>
#include <src/session_transport.h>
#include <src/video.h>

TEST(LumenProtocolAdapterTests, VideoSinkRequestMapsToPrimedPerTilePresentation) {
  video::sink_request_t request {};
  request.capability.transfer = static_cast<int>(video::client_sink_transfer_e::pq);
  request.capability.supports_frame_gated_hdr = true;
  request.capability.supports_hdr_tile_overlay = true;
  request.capability.supports_per_frame_hdr_metadata = true;
  request.capability.supports_encoded_tile_stream = true;
  request.dynamic_range_transport = video::dynamic_range_transport_e::sdr_base_hdr_overlay;

  const auto adapter = video::make_lumen_protocol_adapter(
    request,
    lumen::protocol::encoded_tile_layout {
      .tile_count = 2,
      .encoded_lane_count = 2,
    }
  );

  EXPECT_EQ(adapter.negotiated_transport, lumen::protocol::dynamic_range_transport::sdr_base_hdr_overlay);
  EXPECT_EQ(adapter.presentation_contract, lumen::protocol::presentation_contract::primed_per_tile_update);
  EXPECT_EQ(adapter.presentation_contract_name(), lumen::protocol::presentation::primed_per_tile_update);
  EXPECT_EQ(adapter.presentation_completion_name(), lumen::protocol::presentation::per_tile_after_lane_prime);
}

TEST(LumenProtocolAdapterTests, VideoSinkRequestFallsBackToSingleFrameWithoutEncodedTileSupport) {
  video::sink_request_t request {};
  request.capability.transfer = static_cast<int>(video::client_sink_transfer_e::pq);
  request.capability.supports_frame_gated_hdr = true;
  request.capability.supports_hdr_tile_overlay = true;
  request.capability.supports_per_frame_hdr_metadata = true;
  request.capability.supports_encoded_tile_stream = false;
  request.dynamic_range_transport = video::dynamic_range_transport_e::sdr_base_hdr_overlay;

  const auto adapter = video::make_lumen_protocol_adapter(
    request,
    lumen::protocol::encoded_tile_layout {
      .tile_count = 2,
      .encoded_lane_count = 2,
    }
  );

  EXPECT_EQ(adapter.presentation_contract, lumen::protocol::presentation_contract::single_frame);
  EXPECT_EQ(adapter.presentation_contract_name(), lumen::protocol::presentation::single_frame);
}

TEST(LumenProtocolAdapterTests, VideoConfigAdapterKeepsH264SourcesOnSingleFramePresentation) {
  video::config_t config {};
  config.videoFormat = 0;
  config.sinkRequest.capability.transfer = static_cast<int>(video::client_sink_transfer_e::pq);
  config.sinkRequest.capability.supports_frame_gated_hdr = true;
  config.sinkRequest.capability.supports_hdr_tile_overlay = true;
  config.sinkRequest.capability.supports_per_frame_hdr_metadata = true;
  config.sinkRequest.capability.supports_encoded_tile_stream = true;
  config.sinkRequest.dynamic_range_transport = video::dynamic_range_transport_e::sdr_base_hdr_overlay;

  const auto adapter = video::make_lumen_protocol_adapter(
    config,
    lumen::protocol::encoded_tile_layout {
      .tile_count = 2,
      .encoded_lane_count = 2,
    }
  );

  EXPECT_EQ(adapter.requested_transport, lumen::protocol::dynamic_range_transport::sdr_base_hdr_overlay);
  EXPECT_EQ(adapter.negotiated_transport, lumen::protocol::dynamic_range_transport::sdr);
  EXPECT_EQ(adapter.presentation_contract, lumen::protocol::presentation_contract::single_frame);
}

TEST(LumenProtocolAdapterTests, ParsesSinkCapabilityProtocolValuesThroughSharedAdapter) {
  EXPECT_EQ(
    video::parse_lumen_protocol_client_sink_gamut("p3"),
    static_cast<int>(video::client_sink_gamut_e::display_p3)
  );
  EXPECT_EQ(
    video::parse_lumen_protocol_client_sink_gamut("bt2020"),
    static_cast<int>(video::client_sink_gamut_e::rec2020)
  );
  EXPECT_EQ(
    video::parse_lumen_protocol_client_sink_transfer("st2084"),
    static_cast<int>(video::client_sink_transfer_e::pq)
  );
  EXPECT_EQ(
    video::parse_lumen_protocol_dynamic_range_transport("sdr_base_hdr_overlay"),
    video::dynamic_range_transport_e::sdr_base_hdr_overlay
  );
  EXPECT_EQ(
    video::parse_lumen_protocol_dynamic_range_transport("bogus"),
    video::dynamic_range_transport_e::sdr
  );
}

TEST(LumenProtocolAdapterTests, FormatsSinkCapabilityProtocolValuesThroughSharedAdapter) {
  EXPECT_EQ(
    video::lumen_protocol_client_sink_gamut_name(
      static_cast<int>(video::client_sink_gamut_e::display_p3)
    ),
    std::string_view("display-p3")
  );
  EXPECT_EQ(
    video::lumen_protocol_client_sink_transfer_name(
      static_cast<int>(video::client_sink_transfer_e::pq)
    ),
    std::string_view("pq")
  );
  EXPECT_EQ(
    video::lumen_protocol_dynamic_range_transport_name(
      video::dynamic_range_transport_e::sdr_base_hdr_overlay
    ),
    std::string_view("sdr-base-hdr-overlay")
  );
}

TEST(LumenProtocolAdapterTests, SanitizesSinkLuminanceProtocolNumbersThroughSharedAdapter) {
  EXPECT_FLOAT_EQ(video::parse_lumen_protocol_headroom("2.5"), 2.5f);
  EXPECT_FLOAT_EQ(video::parse_lumen_protocol_headroom("-1.5"), 0.0f);
  EXPECT_FLOAT_EQ(video::parse_lumen_protocol_headroom("2.5x"), 0.0f);

  EXPECT_EQ(video::parse_lumen_protocol_peak_luminance_nits("1600"), 1600);
  EXPECT_EQ(video::parse_lumen_protocol_peak_luminance_nits("-300"), 0);
  EXPECT_EQ(video::parse_lumen_protocol_peak_luminance_nits("1600x"), 0);
}

TEST(LumenProtocolAdapterTests, BuildsSinkRequestFromProtocolFieldsAtAdapterBoundary) {
  const auto request = video::make_lumen_sink_request(
    video::lumen_sink_request_fields_t {
      .scale_explicit = true,
      .mode_is_logical = true,
      .scale_percent = 175,
      .hidpi = true,
      .gamut = "display_p3",
      .transfer = "hdr-pq",
      .current_edr_headroom = "2.75",
      .potential_edr_headroom = "7.5",
      .current_peak_luminance_nits = "800",
      .potential_peak_luminance_nits = "1600",
      .requested_dynamic_range_transport = "frame_gated_hdr",
      .supports_frame_gated_hdr = true,
      .supports_hdr_tile_overlay = true,
      .supports_per_frame_hdr_metadata = true,
      .supports_encoded_tile_stream = true,
    }
  );

  EXPECT_TRUE(request.mode.scale_explicit);
  EXPECT_TRUE(request.mode.mode_is_logical);
  EXPECT_EQ(request.mode.scale_percent, 175);
  EXPECT_TRUE(request.mode.hidpi);
  EXPECT_EQ(request.capability.gamut, static_cast<int>(video::client_sink_gamut_e::display_p3));
  EXPECT_EQ(request.capability.transfer, static_cast<int>(video::client_sink_transfer_e::pq));
  EXPECT_FLOAT_EQ(request.capability.current_edr_headroom, 2.75f);
  EXPECT_FLOAT_EQ(request.capability.potential_edr_headroom, 7.5f);
  EXPECT_EQ(request.capability.current_peak_luminance_nits, 800);
  EXPECT_EQ(request.capability.potential_peak_luminance_nits, 1600);
  EXPECT_EQ(request.dynamic_range_transport, video::dynamic_range_transport_e::frame_gated_hdr);
  EXPECT_TRUE(request.capability.supports_frame_gated_hdr);
  EXPECT_TRUE(request.capability.supports_hdr_tile_overlay);
  EXPECT_TRUE(request.capability.supports_per_frame_hdr_metadata);
  EXPECT_TRUE(request.capability.supports_encoded_tile_stream);
}
