#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)

if [ -z "${PROTOC_GEN_SWIFT:-}" ]; then
    PROTOC_GEN_SWIFT=$("$root/tools/protocol/build_protoc_gen_swift.sh")
    export PROTOC_GEN_SWIFT
fi

python3 "$root/tools/protocol/validate_lumen_contract_v4.py"
python3 "$root/tools/protocol/generate_lumen_contract_v4.py" --check
"$root/tools/protocol/test_generate_lumen_streaming_v4.sh"

python3 - "$root" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
manifest_path = root / "docs/protocol/lumen-streaming-v4.manifest.json"
manifest = json.loads(manifest_path.read_text())

expected_identity = {
    "schemaVersion": 1,
    "protocol": "lumen-stream",
    "protocolVersion": 4,
    "package": "lumen.streaming.v4",
    "alpn": "lumen-stream/4",
}
for key, expected in expected_identity.items():
    actual = manifest.get(key)
    if actual != expected:
        raise SystemExit(f"invalid protocol manifest {key}: expected {expected!r}, got {actual!r}")

for artifact_key in ("schema", "descriptor"):
    artifact = manifest.get(artifact_key)
    if not isinstance(artifact, dict):
        raise SystemExit(f"invalid protocol manifest section: {artifact_key}")
    relative_path = artifact.get("path")
    expected_digest = artifact.get("sha256")
    if not isinstance(relative_path, str) or not isinstance(expected_digest, str):
        raise SystemExit(f"invalid protocol manifest artifact: {artifact_key}")
    path = root / relative_path
    actual_digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual_digest != expected_digest:
        raise SystemExit(
            f"protocol manifest digest mismatch for {relative_path}: "
            f"expected {expected_digest}, got {actual_digest}"
        )
PY
