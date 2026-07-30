#!/usr/bin/env python3
from __future__ import annotations

import copy
import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("check_lumen_contract_v4_compatibility.py")
SPEC = importlib.util.spec_from_file_location("compatibility", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
compatibility = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(compatibility)


def contract() -> dict:
    return {
        "identity": {
            "name": "lumen-stream",
            "version": 4,
            "package": "lumen.streaming.v4",
            "alpn": "lumen-stream/4",
        },
        "protobuf": {
            "source": """syntax = \"proto3\";
message Hello {
  uint32 version = 1;
  reserved 2;
}
"""
        },
        "nativeTransport": {
            "clientBidirectionalStreams": {"control": 0},
            "hostUnidirectionalStreams": {"configuration": 3},
            "mediaDatagramHeader": {"bytes": 28},
            "mediaKinds": {"video": 1},
            "flags": {"keyframe": 1},
            "fecBlockExtension": {"bytes": 8},
            "mediaCapabilities": {"requiredMask": 15},
            "dynamicRangeTransport": {"sdr": 1},
            "videoBootstrap": {"initialGenerationId": 1},
            "telemetry": {"streamId": 8, "parityRangePercentage": [5, 50]},
            "validation": {"reservedFields": "reject"},
            "transportErrors": ["invalid-header"],
            "packetArrivalFeedbackErrors": ["unsupported"],
        },
        "https": {
            "authentication": {
                "protectedRoutes": {
                    "cancel": {"method": "GET", "path": "/cancel"},
                },
                "credentialPolicy": {"accessTokenLifetimeSeconds": 900},
                "envelopes": {"request": {"schemaVersion": 1}},
                "operations": {"cancel": {"request": {"session": "opaque"}}},
                "errorCodes": ["revoked"],
            },
            "settings": {
                "networkTransport": {
                    "routes": {"snapshot": {"method": "GET", "path": "/api/v1/settings"}}
                },
                "envelopes": {"snapshot": ["schemaVersion", "revision"]},
                "fields": [{"key": "general.name", "type": "string", "applyClass": "live"}],
                "errorCodes": ["invalid-value"],
            },
        },
        "lifecycle": {
            "sessionStop": {"request": "StopSession", "response": "SessionStopped"}
        },
    }


class CompatibilityTests(unittest.TestCase):
    def test_unchanged_contract_passes(self) -> None:
        baseline = contract()
        compatibility.compare_contract(baseline, copy.deepcopy(baseline))

    def test_auth_route_and_policy_changes_fail(self) -> None:
        baseline = contract()
        for mutate in (
            lambda value: value["https"]["authentication"]["protectedRoutes"].clear(),
            lambda value: value["https"]["authentication"]["credentialPolicy"].update(
                accessTokenLifetimeSeconds=60
            ),
            lambda value: value["https"]["authentication"]["envelopes"].clear(),
        ):
            current = copy.deepcopy(baseline)
            mutate(current)
            with self.assertRaises(ValueError):
                compatibility.compare_contract(baseline, current)

    def test_settings_field_and_envelope_changes_fail(self) -> None:
        baseline = contract()
        current = copy.deepcopy(baseline)
        current["https"]["settings"]["fields"][0]["type"] = "integer"
        with self.assertRaises(ValueError):
            compatibility.compare_contract(baseline, current)

        current = copy.deepcopy(baseline)
        current["https"]["settings"]["envelopes"]["snapshot"] = ["schemaVersion"]
        with self.assertRaises(ValueError):
            compatibility.compare_contract(baseline, current)

    def test_native_bootstrap_telemetry_and_validation_changes_fail(self) -> None:
        baseline = contract()
        for key in ("videoBootstrap", "telemetry", "validation"):
            current = copy.deepcopy(baseline)
            current["nativeTransport"][key] = {}
            with self.assertRaises(ValueError):
                compatibility.compare_contract(baseline, current)

    def test_protobuf_number_change_fails(self) -> None:
        baseline = contract()
        current = copy.deepcopy(baseline)
        current["protobuf"]["source"] = current["protobuf"]["source"].replace(
            "version = 1", "version = 3"
        )
        with self.assertRaises(ValueError):
            compatibility.compare_contract(baseline, current)

    def test_documentation_collapse_fails(self) -> None:
        baseline = "# Contract\n\n## Lifecycle\n\nUse `StopSession`.\n" * 20
        current = "# Contract\n\nUse `StopSession`.\n"
        with self.assertRaises(ValueError):
            compatibility.compare_documentation(baseline, current, "documentation")


if __name__ == "__main__":
    unittest.main()
