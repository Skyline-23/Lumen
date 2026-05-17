import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def compile_and_run(source: str, binary_name: str) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        source_path = Path(tmp) / f"{binary_name}.cpp"
        binary_path = Path(tmp) / binary_name
        source_path.write_text(textwrap.dedent(source))

        subprocess.run(
            [
                "c++",
                "-std=c++20",
                "-I",
                str(ROOT),
                "-I",
                "/opt/homebrew/include",
                str(source_path),
                "-o",
                str(binary_path),
            ],
            cwd=ROOT,
            check=True,
        )
        subprocess.run([str(binary_path)], cwd=ROOT, check=True)


class PlatformProtocolAdapterTests(unittest.TestCase):
    def test_video_adapter_paths_delegate_through_shared_platform_input(self) -> None:
        compile_and_run(
            """
            #include "src/lumen_protocol_adapter.h"

            #include <cassert>

            int main() {
              video::sink_request_t request {};
              request.capability.transfer = static_cast<int>(video::client_sink_transfer_e::pq);
              request.capability.supports_frame_gated_hdr = true;
              request.capability.supports_hdr_tile_overlay = true;
              request.capability.supports_per_frame_hdr_metadata = true;
              request.capability.supports_encoded_tile_stream = true;
              request.dynamic_range_transport = video::dynamic_range_transport_e::sdr_base_hdr_overlay;

              const lumen::protocol::encoded_tile_layout layout {
                .tile_count = 2,
                .encoded_lane_count = 2,
              };
              const auto input = video::make_lumen_protocol_adapter_input(request, layout);
              const auto shared = video::make_lumen_protocol_adapter(
                lumen::platform::resolve_protocol_adapter(input)
              );
              const auto adapter = video::make_lumen_protocol_adapter(request, layout);

              assert(shared.presentation_signal().requested_transport == adapter.presentation_signal().requested_transport);
              assert(shared.presentation_signal().negotiated_transport == adapter.presentation_signal().negotiated_transport);
              assert(shared.presentation_contract == adapter.presentation_contract);
              return 0;
            }
            """,
            "video_adapter_shared_input_test",
        )

    def test_windows_adapter_maps_dxgi_wgc_nvenc_facts_to_lumen_signal(self) -> None:
        compile_and_run(
            """
            #include "src/platform/windows/lumen_protocol_adapter.h"

            #include <cassert>

            int main() {
              const auto adapter = lumen::platform::windows::make_lumen_protocol_adapter(
                lumen::platform::windows::capture_signal {
                  .requested_transport = lumen::protocol::dynamic_range_transport::sdr_base_hdr_overlay,
                  .sink = {
                    .prefers_hdr = true,
                    .supports_hdr_tile_overlay = true,
                    .supports_per_frame_hdr_metadata = true,
                    .supports_encoded_tile_stream = true,
                  },
                  .source = {
                    .hdr_enabled = true,
                    .capture_backend = lumen::platform::windows::capture_backend::wgc,
                    .encoder = lumen::platform::windows::encoder_backend::nvenc_hevc_main10,
                    .dirty_region_count = 2,
                    .encoded_lane_count = 2,
                  },
                }
              );

              assert(adapter.presentation_signal().requested_transport == lumen::protocol::dynamic_range_transport::sdr_base_hdr_overlay);
              assert(adapter.presentation_signal().negotiated_transport == lumen::protocol::dynamic_range_transport::sdr_base_hdr_overlay);
              assert(adapter.source_layout.tile_count == 2);
              assert(adapter.source_layout.encoded_lane_count == 2);
              assert(adapter.presentation_contract == lumen::protocol::presentation_contract::primed_per_tile_update);
              return 0;
            }
            """,
            "windows_adapter_contract_test",
        )

    def test_macos_adapter_maps_capture_and_videotoolbox_facts_to_lumen_signal(self) -> None:
        compile_and_run(
            """
            #include "src/platform/macos/lumen_protocol_adapter.h"

            #include <cassert>

            int main() {
              const auto adapter = lumen::platform::macos::make_lumen_protocol_adapter(
                lumen::platform::macos::capture_signal {
                  .requested_transport = lumen::protocol::dynamic_range_transport::sdr_base_hdr_overlay,
                  .sink = {
                    .prefers_hdr = true,
                    .supports_hdr_tile_overlay = true,
                    .supports_per_frame_hdr_metadata = true,
                    .supports_encoded_tile_stream = true,
                  },
                  .source = {
                    .hdr_enabled = true,
                    .capture_backend = lumen::platform::macos::capture_backend::screen_capture_kit,
                    .encoder = lumen::platform::macos::encoder_backend::videotoolbox_hevc_main10,
                    .tile_count = 2,
                    .encoded_lane_count = 2,
                  },
                }
              );

              assert(adapter.presentation_signal().requested_transport == lumen::protocol::dynamic_range_transport::sdr_base_hdr_overlay);
              assert(adapter.presentation_signal().negotiated_transport == lumen::protocol::dynamic_range_transport::sdr_base_hdr_overlay);
              assert(adapter.source_layout.tile_count == 2);
              assert(adapter.source_layout.encoded_lane_count == 2);
              assert(adapter.presentation_contract == lumen::protocol::presentation_contract::primed_per_tile_update);
              return 0;
            }
            """,
            "macos_adapter_contract_test",
        )

    def test_platform_adapters_share_h264_sdr_fallback_contract(self) -> None:
        compile_and_run(
            """
            #include "src/platform/macos/lumen_protocol_adapter.h"
            #include "src/platform/windows/lumen_protocol_adapter.h"

            #include <cassert>

            int main() {
              const lumen::protocol::sink_capability sink {
                .prefers_hdr = true,
                .supports_hdr_tile_overlay = true,
                .supports_per_frame_hdr_metadata = true,
                .supports_encoded_tile_stream = true,
              };

              const auto mac = lumen::platform::macos::make_lumen_protocol_adapter(
                lumen::platform::macos::capture_signal {
                  .requested_transport = lumen::protocol::dynamic_range_transport::sdr_base_hdr_overlay,
                  .sink = sink,
                  .source = {
                    .hdr_enabled = true,
                    .capture_backend = lumen::platform::macos::capture_backend::core_display,
                    .encoder = lumen::platform::macos::encoder_backend::videotoolbox_h264,
                    .tile_count = 2,
                    .encoded_lane_count = 2,
                  },
                }
              );
              const auto windows = lumen::platform::windows::make_lumen_protocol_adapter(
                lumen::platform::windows::capture_signal {
                  .requested_transport = lumen::protocol::dynamic_range_transport::sdr_base_hdr_overlay,
                  .sink = sink,
                  .source = {
                    .hdr_enabled = true,
                    .capture_backend = lumen::platform::windows::capture_backend::dxgi,
                    .encoder = lumen::platform::windows::encoder_backend::nvenc_h264,
                    .dirty_region_count = 2,
                    .encoded_lane_count = 2,
                  },
                }
              );

              assert(mac.presentation_signal().negotiated_transport == lumen::protocol::dynamic_range_transport::sdr);
              assert(windows.presentation_signal().negotiated_transport == lumen::protocol::dynamic_range_transport::sdr);
              assert(mac.presentation_contract == lumen::protocol::presentation_contract::single_frame);
              assert(windows.presentation_contract == lumen::protocol::presentation_contract::single_frame);
              return 0;
            }
            """,
            "platform_h264_fallback_contract_test",
        )


if __name__ == "__main__":
    unittest.main()
