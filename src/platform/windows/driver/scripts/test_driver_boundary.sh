#!/usr/bin/env bash
set -euo pipefail

DRIVER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "${DRIVER_ROOT}/../../../.." && pwd)"
BUILD_DIR="${DRIVER_ROOT}/build/platform-neutral"

cd "${REPO_ROOT}"
cargo test --locked -p lumen-windows-driver-core
cargo build --locked -p lumen-windows-driver-core

cmake \
  -S "${DRIVER_ROOT}" \
  -B "${BUILD_DIR}" \
  -DLUMEN_DRIVER_CORE_LIBRARY="${REPO_ROOT}/target/debug/liblumen_windows_driver_core.a"
cmake --build "${BUILD_DIR}" --parallel
ctest --test-dir "${BUILD_DIR}" --output-on-failure
