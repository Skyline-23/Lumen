#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)

if [ -z "${PROTOC_GEN_SWIFT:-}" ]; then
    PROTOC_GEN_SWIFT=$("$root/tools/protocol/build_protoc_gen_swift.sh")
    export PROTOC_GEN_SWIFT
fi

(
    cd "$root"
    swift build --product lumen-contract-tool
    contract_tool=$(swift build --show-bin-path)/lumen-contract-tool
    "$contract_tool" validate
    "$contract_tool" check
)
"$root/tools/protocol/test_generate_lumen_streaming_v4.sh"
