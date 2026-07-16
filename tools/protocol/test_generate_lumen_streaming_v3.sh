#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/lumen-protocol-v3-transaction.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

mkdir -p \
    "$scratch/tools/protocol" \
    "$scratch/docs/protocol" \
    "$scratch/engine/lumen-engine/src/protocol"
cp "$root/tools/protocol/generate_lumen_streaming_v3.sh" "$scratch/tools/protocol/"
cp "$root/docs/protocol/lumen-streaming-v3.proto" "$scratch/docs/protocol/"
cp "$scratch/docs/protocol/lumen-streaming-v3.proto" "$scratch/original.proto"

generator="$scratch/tools/protocol/generate_lumen_streaming_v3.sh"
descriptor="$scratch/docs/protocol/lumen-streaming-v3.descriptor.pb"
schema_digest="$scratch/docs/protocol/lumen-streaming-v3.sha256"
generated_rust="$scratch/engine/lumen-engine/src/protocol/lumen_streaming_v3_provenance.rs"

artifact_hashes() {
    shasum -a 256 "$descriptor" "$schema_digest" "$generated_rust"
}

"$generator" write
baseline=$(artifact_hashes)

for fault in descriptor schema_digest rust_provenance; do
    printf '\n' >> "$scratch/docs/protocol/lumen-streaming-v3.proto"
    if LUMEN_PROTOCOL_CODEGEN_FAIL_AFTER="$fault" "$generator" write; then
        printf 'fault injection point did not fail: %s\n' "$fault" >&2
        exit 1
    fi
    cp "$scratch/original.proto" "$scratch/docs/protocol/lumen-streaming-v3.proto"
    test "$(artifact_hashes)" = "$baseline"
    "$generator" --check
    if find "$scratch" -type f \( -name '*.new.*' -o -name '*.backup.*' \) -print -quit | grep -q .; then
        printf 'transaction residue remained after: %s\n' "$fault" >&2
        exit 1
    fi
    printf 'rollback_and_check_after_%s=pass\n' "$fault"
done
