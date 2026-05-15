/**
 * @file tests/unit/test_lumen_protocol.cpp
 * @brief Test Lumen protocol adapter contracts.
 */
#include <gtest/gtest.h>

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
