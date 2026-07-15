#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
schema="$root/docs/protocol/lumen-streaming-v3.proto"
descriptor="$root/docs/protocol/lumen-streaming-v3.descriptor.pb"
schema_digest="$root/docs/protocol/lumen-streaming-v3.sha256"
generated_rust="$root/engine/lumen-engine/src/protocol/lumen_streaming_v3_provenance.rs"
mode=${1:-write}

if [ "$mode" != write ] && [ "$mode" != --check ]; then
    echo "usage: $0 [write|--check]" >&2
    exit 64
fi

temporary=$(mktemp -d "${TMPDIR:-/tmp}/lumen-protocol-v3.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

protoc \
    --proto_path="$(dirname -- "$schema")" \
    --include_imports \
    --descriptor_set_out="$temporary/lumen-streaming-v3.descriptor.pb" \
    "$(basename -- "$schema")"

schema_sha=$(shasum -a 256 "$schema" | awk '{print $1}')
descriptor_sha=$(shasum -a 256 "$temporary/lumen-streaming-v3.descriptor.pb" | awk '{print $1}')
printf '%s  lumen-streaming-v3.proto\n' "$schema_sha" > "$temporary/lumen-streaming-v3.sha256"
printf '%s\n' \
    "pub const LUMEN_STREAMING_PROTOCOL_PACKAGE: &str = \"lumen.streaming.v3\";" \
    "pub const LUMEN_STREAMING_PROTOCOL_ALPN: &[u8] = b\"lumen-stream/3\";" \
    "pub const LUMEN_STREAMING_EXPORTER_LABEL: &[u8] = b\"EXPORTER-Lumen-Session-v3\";" \
    "pub const LUMEN_STREAMING_SCHEMA_SHA256: &str = \"$schema_sha\";" \
    "pub const LUMEN_STREAMING_DESCRIPTOR_SHA256: &str = \"$descriptor_sha\";" \
    > "$temporary/lumen_streaming_v3_provenance.rs"
rustfmt --edition 2021 "$temporary/lumen_streaming_v3_provenance.rs"

if [ "$mode" = --check ]; then
    cmp "$temporary/lumen-streaming-v3.descriptor.pb" "$descriptor"
    cmp "$temporary/lumen-streaming-v3.sha256" "$schema_digest"
    cmp "$temporary/lumen_streaming_v3_provenance.rs" "$generated_rust"
else
    install -m 0644 "$temporary/lumen-streaming-v3.descriptor.pb" "$descriptor"
    install -m 0644 "$temporary/lumen-streaming-v3.sha256" "$schema_digest"
    install -m 0644 "$temporary/lumen_streaming_v3_provenance.rs" "$generated_rust"
fi
