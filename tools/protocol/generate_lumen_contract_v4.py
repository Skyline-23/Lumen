#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
CONTRACT = ROOT / "docs/protocol/lumen-contract-v4.json"


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode()


def render_proto(contract: dict[str, Any]) -> bytes:
    protobuf = contract["protobuf"]
    if "source" in protobuf:
        return protobuf["source"].encode()
    lines = [
        f'syntax = "{protobuf["syntax"]}";',
        "",
        f'package {protobuf["package"]};',
        "",
    ]
    for declaration in protobuf["declarations"]:
        lines.append(f'{declaration["kind"]} {declaration["name"]} {{')
        reserved = declaration.get("reservedNumbers", [])
        if reserved:
            lines.append("  reserved " + ", ".join(str(value) for value in reserved) + ";")
        if declaration["kind"] == "enum":
            for value in declaration["values"]:
                lines.append(f'  {value["name"]} = {value["number"]};')
        else:
            active_oneof: str | None = None
            for field in declaration["fields"]:
                oneof = field.get("oneof")
                if oneof != active_oneof:
                    if active_oneof is not None:
                        lines.append("  }")
                    if oneof is not None:
                        lines.append(f"  oneof {oneof} {{")
                    active_oneof = oneof
                indent = "    " if oneof is not None else "  "
                cardinality = field.get("cardinality")
                prefix = f"{cardinality} " if cardinality is not None else ""
                lines.append(
                    f'{indent}{prefix}{field["type"]} {field["name"]} = {field["number"]};'
                )
            if active_oneof is not None:
                lines.append("  }")
        lines.extend(["}", ""])
    return ("\n".join(lines).rstrip() + "\n").encode()


def render_streaming_document(contract: dict[str, Any]) -> bytes:
    identity = contract["identity"]
    native = contract["nativeTransport"]
    lifecycle = contract["lifecycle"]
    capabilities = native["mediaCapabilities"]
    lines = [
        "# Lumen Streaming Protocol v4",
        "",
        "This document is generated from `lumen-contract-v4.json`.",
        "",
        "## Identity",
        "",
        f'- Protocol: `{identity["name"]}` version `{identity["version"]}`',
        f'- Protobuf package: `{identity["package"]}`',
        f'- QUIC ALPN: `{identity["alpn"]}`',
        "- TLS 1.3 QUIC streams carry control and reliable objects; QUIC DATAGRAM carries deadline-bound media and motion.",
        "",
        "## Fixed stream roles",
        "",
        "| Direction | Raw stream id | Role |",
        "| --- | ---: | --- |",
    ]
    for role, stream_id in native["clientBidirectionalStreams"].items():
        lines.append(f"| client bidirectional | {stream_id} | {role} |")
    for role, stream_id in native["hostUnidirectionalStreams"].items():
        if isinstance(stream_id, int):
            lines.append(f"| host unidirectional | {stream_id} | {role} |")
    lines.extend(["", "## Media capability bits", "", "| Capability | Value |", "| --- | ---: |"])
    for name, value in capabilities.items():
        lines.append(f"| {name} | {value} |")
    lines.extend(["", "## Codec bootstrap", ""])
    for index, step in enumerate(lifecycle["codecBootstrapSequence"], start=1):
        lines.append(f"{index}. `{step}`")
    lines.extend(
        [
            "",
            "Dependent video deltas are forbidden until the matching hardware-decoded bootstrap result.",
            "",
            "## Session lifecycle",
            "",
            f'- Stop request: `{lifecycle["sessionStop"]["request"]}`',
            f'- Required stop response: `{lifecycle["sessionStop"]["response"]}`',
            "- The client completes teardown only after the matching session-epoch response.",
            "- Display reconfiguration revisions are strictly increasing and generation-fenced.",
            "- Legacy protocols, silent format downgrade, and compatibility fallback are forbidden.",
            "",
            "## Native object plane",
            "",
            "The exact header layout, flags, FEC constants, validation rules, and typed errors are generated in `lumen-native-transport-conformance.json`.",
            "The exact protobuf messages, field numbers, enum values, and reserved fields are generated in `lumen-streaming-v4.proto` and its descriptor set.",
            "",
        ]
    )
    return "\n".join(lines).encode()


def render_settings_document(contract: dict[str, Any]) -> bytes:
    settings = contract["https"]["settings"]
    routes = settings["networkTransport"]["routes"]
    lines = [
        "# Lumen Settings Protocol v1",
        "",
        "This document is generated from `lumen-contract-v4.json`.",
        "",
        "## HTTPS routes",
        "",
        "| Operation | Method | Path |",
        "| --- | --- | --- |",
    ]
    for name, route in routes.items():
        lines.append(f'| {name} | {route["method"]} | `{route["path"]}` |')
    lines.extend(
        [
            "",
            "Requests use the Lumen device Bearer token and `Lumen-Device-ID` header.",
            "Patches are atomic, revision-checked, idempotent by request id, and never use a legacy migration path.",
            "The complete field catalog, envelopes, apply states, capabilities, and typed errors are generated in `lumen-settings-conformance.json`.",
            "",
        ]
    )
    return "\n".join(lines).encode()


def swift_contract_source(contract: dict[str, Any], digest: str) -> bytes:
    identity = contract["identity"]
    source = f'''import Foundation

public enum LumenContract {{
    public static let schemaVersion: UInt32 = {contract["schemaVersion"]}
    public static let protocolVersion: UInt32 = {identity["version"]}
    public static let protocolName = "{identity["name"]}"
    public static let protobufPackage = "{identity["package"]}"
    public static let alpn = "{identity["alpn"]}"
    public static let contractSHA256 = "{digest}"

    public static func contractData() throws -> Data {{
        guard let url = Bundle.module.url(forResource: "lumen-contract-v4", withExtension: "json") else {{
            throw LumenContractResourceError.missingContract
        }}
        return try Data(contentsOf: url)
    }}
}}

public enum LumenContractResourceError: Error {{
    case missingContract
}}
'''
    return source.encode()


def generated_swift_protobuf(proto: bytes) -> bytes:
    compiler = os.environ.get("PROTOC_GEN_SWIFT") or shutil.which("protoc-gen-swift")
    if compiler is None:
        raise SystemExit(
            "protoc-gen-swift is required to generate LumenClientContracts; "
            "run tools/protocol/build_protoc_gen_swift.sh and set PROTOC_GEN_SWIFT"
        )
    with tempfile.TemporaryDirectory(prefix="lumen-swift-protobuf-") as directory:
        temporary = Path(directory)
        schema = temporary / "lumen-streaming-v4.proto"
        schema.write_bytes(proto)
        subprocess.run(
            [
                "protoc",
                f"--plugin=protoc-gen-swift={compiler}",
                f"--proto_path={temporary}",
                f"--swift_out=Visibility=Public:{temporary}",
                schema.name,
            ],
            check=True,
        )
        return (temporary / "lumen-streaming-v4.pb.swift").read_bytes()


def expected_outputs(contract_bytes: bytes, contract: dict[str, Any]) -> dict[Path, bytes]:
    digest = hashlib.sha256(contract_bytes).hexdigest()
    proto = render_proto(contract)
    swift_protobuf = generated_swift_protobuf(proto)
    manifest = {
        "schemaVersion": 1,
        "contract": {
            "path": "docs/protocol/lumen-contract-v4.json",
            "sha256": digest,
        },
        "identity": contract["identity"],
        "generatedArtifacts": [
            "docs/protocol/lumen-streaming-v4.proto",
            "docs/protocol/lumen-streaming-v4.descriptor.pb",
            "docs/protocol/lumen-streaming-v4.sha256",
            "docs/protocol/lumen-native-transport-conformance.json",
            "docs/protocol/lumen-auth-conformance.json",
            "docs/protocol/lumen-settings-conformance.json",
            "Sources/LumenClientContracts/LumenStreamingV4.pb.swift",
        ],
        "handwrittenRuntimeBoundary": {
            "status": "drift-gated",
            "path": "engine/lumen-engine/src/protocol",
            "note": "Runtime policy and validators remain handwritten and must pass descriptor and source contract gates.",
        },
        "handwrittenDocumentationBoundary": {
            "status": "drift-gated",
            "paths": [
                "docs/protocol/lumen-streaming-protocol.md",
                "docs/protocol/lumen-settings-protocol.md"
            ],
            "note": "Complete lifecycle and policy prose remains handwritten until every semantic rule is represented structurally in the IDL."
        },
    }
    outputs = {
        ROOT / "docs/protocol/lumen-streaming-v4.proto": proto,
        ROOT / "docs/protocol/lumen-native-transport-conformance.json": canonical_json(
            contract["nativeTransport"]
        ),
        ROOT / "docs/protocol/lumen-auth-conformance.json": canonical_json(
            contract["https"]["authentication"]
        ),
        ROOT / "docs/protocol/lumen-settings-conformance.json": contract["rendering"][
            "settingsConformance"
        ].encode(),
        ROOT / "docs/protocol/lumen-contract-v4.manifest.json": canonical_json(manifest),
        ROOT / "Sources/LumenClientContracts/LumenStreamingV4.pb.swift": swift_protobuf,
        ROOT / "Sources/LumenClientContracts/Resources/lumen-contract-v4.json": contract_bytes,
        ROOT / "Sources/LumenClientContracts/LumenContract.swift": swift_contract_source(
            contract, digest
        ),
    }
    return outputs


def replace_file(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as temporary:
            temporary.write(content)
        os.replace(temporary_name, path)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)


def check_outputs(outputs: dict[Path, bytes]) -> None:
    mismatches = []
    for path, expected in outputs.items():
        if not path.exists() or path.read_bytes() != expected:
            mismatches.append(path.relative_to(ROOT))
    if mismatches:
        joined = "\n".join(f"generated contract drift: {path}" for path in mismatches)
        raise SystemExit(joined)


def run_descriptor_generation(mode: str) -> None:
    command = [str(ROOT / "tools/protocol/generate_lumen_streaming_v4.sh")]
    command.append("--check" if mode == "--check" else "write")
    subprocess.run(command, cwd=ROOT, check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate the public Lumen v4 contract package.")
    parser.add_argument("mode", nargs="?", choices=("write",), default="write")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    mode = "--check" if args.check else args.mode

    contract_bytes = CONTRACT.read_bytes()
    contract = json.loads(contract_bytes)
    identity = contract.get("identity", {})
    if identity != {
        "name": "lumen-stream",
        "version": 4,
        "package": "lumen.streaming.v4",
        "alpn": "lumen-stream/4",
    }:
        raise SystemExit("invalid Lumen v4 contract identity")
    outputs = expected_outputs(contract_bytes, contract)
    if mode == "--check":
        check_outputs(outputs)
    else:
        for path, content in outputs.items():
            replace_file(path, content)
    run_descriptor_generation(mode)
    return 0


if __name__ == "__main__":
    sys.exit(main())
