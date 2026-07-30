#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
CONTRACT = ROOT / "docs/protocol/lumen-contract-v4.json"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def require_keys(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{label} must be an object")
    missing = keys.difference(value)
    require(not missing, f"{label} is missing: {', '.join(sorted(missing))}")
    return value


def validate(contract: dict[str, Any]) -> None:
    require(contract.get("schemaVersion") == 1, "schemaVersion must be 1")
    require(
        contract.get("$schema") == "https://lumen.skyline23.com/schemas/contract-v1.json",
        "contract must reference the committed meta-schema",
    )
    identity = require_keys(contract.get("identity"), {"name", "version", "package", "alpn"}, "identity")
    require(
        identity
        == {
            "name": "lumen-stream",
            "version": 4,
            "package": "lumen.streaming.v4",
            "alpn": "lumen-stream/4",
        },
        "invalid protocol identity",
    )
    protobuf = require_keys(contract.get("protobuf"), {"syntax", "package", "source"}, "protobuf")
    source = protobuf["source"]
    require(isinstance(source, str), "protobuf.source must be a string")
    for fragment in (
        'syntax = "proto3";',
        "package lumen.streaming.v4;",
        "reserved 3;",
        "reserved 8;",
        "reserved 7, 8, 9;",
        "uint64 media_capabilities = 46;",
        "StopSession stop_session = 13;",
        "SessionStopped session_stopped = 12;",
    ):
        require(fragment in source, f"protobuf source is missing required boundary: {fragment}")

    native = require_keys(
        contract.get("nativeTransport"),
        {"flags", "videoBootstrap", "telemetry", "mediaCapabilities", "dynamicRangeTransport", "validation"},
        "nativeTransport",
    )
    require(native["flags"].get("keyframe") == 1, "keyframe flag must be 0x01")
    require(native["videoBootstrap"].get("periodicByDefault") is True, "periodic keyframe scheduling must preserve v4 authority")
    require(native["telemetry"].get("parityRangePercentage") == [5, 50], "telemetry parity range must preserve v4 authority")
    require(
        native["mediaCapabilities"].get("requiredMask") == 15
        and native["mediaCapabilities"].get("supportedMask") == 31,
        "media capability masks must match protocol v4",
    )
    require(
        native["dynamicRangeTransport"]
        == {"unknown": 0, "sdr": 1, "fullFrameHdr": 2, "frameGatedHdr": 3, "sdrBaseHdrOverlay": 4},
        "dynamic-range transport values must match the native ABI",
    )

    authentication = require_keys(contract.get("https"), {"authentication", "settings"}, "https")["authentication"]
    routes = authentication.get("protectedRoutes", {})
    actual_routes = {(route.get("method"), route.get("path")) for route in routes.values()}
    require(
        actual_routes
        == {
            ("GET", "/api/discovery/apps"),
            ("GET", "/launch"),
            ("GET", "/resume"),
            ("GET", "/cancel"),
            ("GET", "/actions/clipboard"),
            ("POST", "/actions/clipboard"),
        },
        "authentication conformance must preserve every v4 protected route",
    )
    rendering = require_keys(contract.get("rendering"), {"settingsConformance"}, "rendering")
    require(
        json.loads(rendering["settingsConformance"]) == contract["https"]["settings"],
        "settings conformance rendering must match the structured authority",
    )

    lifecycle = require_keys(contract.get("lifecycle"), {"codecBootstrapSequence", "generation", "sessionStop", "displayReconfiguration", "fallback"}, "lifecycle")
    require(lifecycle["sessionStop"].get("responseRequiredBeforeClientCompletion") is True, "StopSession completion requires SessionStopped")
    require(lifecycle["fallback"] == {"legacyProtocol": False, "silentFormatDowngrade": False}, "fallback is forbidden")


def main() -> int:
    try:
        contract = json.loads(CONTRACT.read_text())
        validate(contract)
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"invalid Lumen v4 contract: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
