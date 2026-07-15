#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
OUTPUT="${REPO_ROOT}/third-party/licenses/Rust-Crates.html"
TEMP_OUTPUT=$(mktemp "${TMPDIR:-/tmp}/lumen-rust-licenses.XXXXXX")
trap 'rm -f "${TEMP_OUTPUT}" "${TEMP_OUTPUT}.normalized"' EXIT

if ! command -v cargo-about >/dev/null 2>&1; then
    echo "cargo-about is required; install it with: cargo install cargo-about --locked --features cli" >&2
    exit 1
fi

cd "${REPO_ROOT}"
cargo about generate about.hbs \
    --workspace \
    --locked \
    --fail \
    --output-file "${TEMP_OUTPUT}"
LC_ALL=C sed 's/[[:space:]]*$//' "${TEMP_OUTPUT}" > "${TEMP_OUTPUT}.normalized"
mv "${TEMP_OUTPUT}.normalized" "${TEMP_OUTPUT}"

case "${1:-}" in
    "")
        mv "${TEMP_OUTPUT}" "${OUTPUT}"
        ;;
    --check)
        if ! cmp -s "${TEMP_OUTPUT}" "${OUTPUT}"; then
            echo "Rust dependency license report is stale; regenerate it with $0" >&2
            exit 1
        fi
        ;;
    *)
        echo "usage: $0 [--check]" >&2
        exit 2
        ;;
esac
