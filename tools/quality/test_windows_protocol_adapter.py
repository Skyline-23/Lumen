import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class WindowsProtocolAdapterTests(unittest.TestCase):
    def test_windows_adapter_maps_dxgi_wgc_nvenc_facts_to_lumen_signal(self) -> None:
        source = textwrap.dedent(
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
            """
        )

        with tempfile.TemporaryDirectory() as tmp:
            source_path = Path(tmp) / "windows_adapter_test.cpp"
            binary_path = Path(tmp) / "windows_adapter_test"
            source_path.write_text(source)

            subprocess.run(
                [
                    "c++",
                    "-std=c++20",
                    "-I",
                    str(ROOT),
                    str(source_path),
                    "-o",
                    str(binary_path),
                ],
                cwd=ROOT,
                check=True,
            )
            subprocess.run([str(binary_path)], cwd=ROOT, check=True)

    def test_windows_adapter_falls_back_without_hevc_main10_or_encoded_tiles(self) -> None:
        source = textwrap.dedent(
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
                    .capture_backend = lumen::platform::windows::capture_backend::dxgi,
                    .encoder = lumen::platform::windows::encoder_backend::nvenc_h264,
                    .dirty_region_count = 2,
                    .encoded_lane_count = 2,
                  },
                }
              );

              assert(adapter.presentation_signal().requested_transport == lumen::protocol::dynamic_range_transport::sdr_base_hdr_overlay);
              assert(adapter.presentation_signal().negotiated_transport == lumen::protocol::dynamic_range_transport::sdr);
              assert(adapter.presentation_contract == lumen::protocol::presentation_contract::single_frame);
              return 0;
            }
            """
        )

        with tempfile.TemporaryDirectory() as tmp:
            source_path = Path(tmp) / "windows_adapter_fallback_test.cpp"
            binary_path = Path(tmp) / "windows_adapter_fallback_test"
            source_path.write_text(source)

            subprocess.run(
                [
                    "c++",
                    "-std=c++20",
                    "-I",
                    str(ROOT),
                    str(source_path),
                    "-o",
                    str(binary_path),
                ],
                cwd=ROOT,
                check=True,
            )
            subprocess.run([str(binary_path)], cwd=ROOT, check=True)


if __name__ == "__main__":
    unittest.main()
