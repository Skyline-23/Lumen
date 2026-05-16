import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("generate_lumen_protocol.py")
SPEC = importlib.util.spec_from_file_location("generate_lumen_protocol", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class GenerateLumenProtocolTests(unittest.TestCase):
    def test_generates_cpp_and_swift_control_wire_authority_from_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fixture = root / "docs" / "protocol" / "lumen-protocol-conformance.json"
            cpp_output = root / "src" / "lumen_protocol_control_wire_generated.h"
            swift_output = (
                root
                / "src"
                / "platform"
                / "macos"
                / "Projects"
                / "LumenMacBridge"
                / "Sources"
                / "Generated"
                / "LumenProtocolControlWireLayout.generated.swift"
            )
            fixture.parent.mkdir(parents=True)
            fixture.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "controlWire": {
                            "headerSize": 4,
                            "hdrFrameState": {
                                "packetType": 12291,
                                "version": 1,
                                "flags": {
                                    "hasStaticMetadata": 1,
                                    "hasOverlayRegions": 2,
                                    "overlayRegionHasMetadata": 1,
                                },
                                "offsets": {
                                    "version": 4,
                                    "frameDynamicRange": 5,
                                    "flags": 6,
                                    "effectiveFromFrameNumber": 8,
                                    "overlayRegionCount": 12,
                                    "staticMetadata": 16,
                                },
                            },
                            "encodedTileFrameState": {
                                "packetType": 12292,
                                "version": 1,
                                "flags": {
                                    "hasTileRegion": 1,
                                },
                                "packetLength": 52,
                                "payloadLength": 48,
                                "offsets": {
                                    "version": 4,
                                    "flags": 5,
                                    "effectiveFromFrameNumber": 8,
                                    "frameGroupId": 12,
                                    "tileIndex": 20,
                                    "tileCount": 24,
                                    "encodedLaneIndex": 28,
                                    "encodedLaneCount": 32,
                                    "tileOriginX": 36,
                                    "tileOriginY": 40,
                                    "tileWidth": 44,
                                    "tileHeight": 48,
                                },
                            },
                        },
                    }
                )
            )

            MODULE.generate(root=root)

            self.assertTrue(cpp_output.exists())
            self.assertTrue(swift_output.exists())
            cpp_text = cpp_output.read_text()
            swift_text = swift_output.read_text()

        self.assertIn("hdr_frame_state_type = 0x3003", cpp_text)
        self.assertIn("encoded_tile_frame_state_type = 0x3004", cpp_text)
        self.assertIn("hdr_frame_state_static_metadata_offset = header_size + 12", cpp_text)
        self.assertIn("public enum LumenProtocolControlWireLayout", swift_text)
        self.assertIn("public static let packetType: UInt16 = 0x3003", swift_text)
        self.assertIn("public static let payloadLength: UInt16 = 48", swift_text)

    def test_detects_stale_generated_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fixture = root / "docs" / "protocol" / "lumen-protocol-conformance.json"
            cpp_output = root / "src" / "lumen_protocol_control_wire_generated.h"
            swift_output = (
                root
                / "src"
                / "platform"
                / "macos"
                / "Projects"
                / "LumenMacBridge"
                / "Sources"
                / "Generated"
                / "LumenProtocolControlWireLayout.generated.swift"
            )
            fixture.parent.mkdir(parents=True)
            fixture.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "controlWire": {
                            "headerSize": 4,
                            "hdrFrameState": {
                                "packetType": 12291,
                                "version": 1,
                                "flags": {
                                    "hasStaticMetadata": 1,
                                    "hasOverlayRegions": 2,
                                    "overlayRegionHasMetadata": 1,
                                },
                                "offsets": {
                                    "version": 4,
                                    "frameDynamicRange": 5,
                                    "flags": 6,
                                    "effectiveFromFrameNumber": 8,
                                    "overlayRegionCount": 12,
                                    "staticMetadata": 16,
                                },
                            },
                            "encodedTileFrameState": {
                                "packetType": 12292,
                                "version": 1,
                                "flags": {
                                    "hasTileRegion": 1,
                                },
                                "packetLength": 52,
                                "payloadLength": 48,
                                "offsets": {
                                    "version": 4,
                                    "flags": 5,
                                    "effectiveFromFrameNumber": 8,
                                    "frameGroupId": 12,
                                    "tileIndex": 20,
                                    "tileCount": 24,
                                    "encodedLaneIndex": 28,
                                    "encodedLaneCount": 32,
                                    "tileOriginX": 36,
                                    "tileOriginY": 40,
                                    "tileWidth": 44,
                                    "tileHeight": 48,
                                },
                            },
                        },
                    }
                )
            )
            cpp_output.parent.mkdir(parents=True)
            swift_output.parent.mkdir(parents=True)
            cpp_output.write_text("stale\n")
            swift_output.write_text("stale\n")

            stale = MODULE.find_stale_outputs(root=root)

        self.assertEqual(stale, [MODULE.CPP_OUTPUT_PATH, MODULE.SWIFT_OUTPUT_PATH])


if __name__ == "__main__":
    unittest.main()
