#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
version=1.38.1
revision=55d7a1cc5666b85c13464aea1c4b4a90feccb4c8
cache_root=${LUMEN_PROTOCOL_TOOL_CACHE:-"$root/build/protocol-tools"}
source_root="$cache_root/swift-protobuf-$version-source"
build_root="$cache_root/swift-protobuf-$version-build"
binary="$build_root/release/protoc-gen-swift"

if [ -x "$binary" ]; then
    printf '%s\n' "$binary"
    exit 0
fi

mkdir -p "$cache_root"
if [ ! -d "$source_root/.git" ]; then
    git clone --filter=blob:none --no-checkout https://github.com/apple/swift-protobuf.git "$source_root"
    git -C "$source_root" checkout --detach "$revision"
fi

actual_revision=$(git -C "$source_root" rev-parse HEAD)
if [ "$actual_revision" != "$revision" ]; then
    printf 'unexpected swift-protobuf cache revision: %s\n' "$actual_revision" >&2
    exit 1
fi

swift build \
    --package-path "$source_root" \
    --scratch-path "$build_root" \
    --configuration release \
    --product protoc-gen-swift \
    >&2

test -x "$binary"
printf '%s\n' "$binary"
