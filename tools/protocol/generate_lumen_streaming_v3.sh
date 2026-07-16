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
descriptor_stage="${descriptor}.new.$$"
schema_digest_stage="${schema_digest}.new.$$"
generated_rust_stage="${generated_rust}.new.$$"
descriptor_backup="${descriptor}.backup.$$"
schema_digest_backup="${schema_digest}.backup.$$"
generated_rust_backup="${generated_rust}.backup.$$"
descriptor_existed=0
schema_digest_existed=0
generated_rust_existed=0
transaction_active=0

restore_artifact() {
    target=$1
    backup=$2
    existed=$3
    if [ "$existed" -eq 1 ]; then
        mv -f "$backup" "$target"
    else
        rm -f "$target"
    fi
}

cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    set +e
    if [ "$transaction_active" -eq 1 ]; then
        restore_artifact "$descriptor" "$descriptor_backup" "$descriptor_existed"
        restore_artifact "$schema_digest" "$schema_digest_backup" "$schema_digest_existed"
        restore_artifact "$generated_rust" "$generated_rust_backup" "$generated_rust_existed"
    fi
    rm -f \
        "$descriptor_stage" "$schema_digest_stage" "$generated_rust_stage" \
        "$descriptor_backup" "$schema_digest_backup" "$generated_rust_backup"
    rm -rf "$temporary"
    exit "$status"
}

publish_artifact() {
    staged=$1
    target=$2
    fault=$3
    mv -f "$staged" "$target"
    if [ "${LUMEN_PROTOCOL_CODEGEN_FAIL_AFTER:-}" = "$fault" ]; then
        printf 'injected protocol publication failure after %s\n' "$fault" >&2
        exit 75
    fi
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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
    install -m 0644 "$temporary/lumen-streaming-v3.descriptor.pb" "$descriptor_stage"
    install -m 0644 "$temporary/lumen-streaming-v3.sha256" "$schema_digest_stage"
    install -m 0644 "$temporary/lumen_streaming_v3_provenance.rs" "$generated_rust_stage"
    if [ -e "$descriptor" ]; then
        cp -p "$descriptor" "$descriptor_backup"
        descriptor_existed=1
    fi
    if [ -e "$schema_digest" ]; then
        cp -p "$schema_digest" "$schema_digest_backup"
        schema_digest_existed=1
    fi
    if [ -e "$generated_rust" ]; then
        cp -p "$generated_rust" "$generated_rust_backup"
        generated_rust_existed=1
    fi
    transaction_active=1
    publish_artifact "$descriptor_stage" "$descriptor" descriptor
    publish_artifact "$schema_digest_stage" "$schema_digest" schema_digest
    publish_artifact "$generated_rust_stage" "$generated_rust" rust_provenance
    transaction_active=0
fi
