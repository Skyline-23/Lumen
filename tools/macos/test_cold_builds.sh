#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMMIT="$(git -C "${REPO_ROOT}" rev-parse "${1:-HEAD}")"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/lumen-cold-builds.XXXXXX")"

cleanup() {
  rm -rf "${SCRATCH}"
}
trap cleanup EXIT HUP INT TERM

CLONE_ROOT="${SCRATCH}/repo"
git clone --quiet --no-local "${REPO_ROOT}" "${CLONE_ROOT}"
git -C "${CLONE_ROOT}" checkout --quiet --detach "${COMMIT}"
git -C "${CLONE_ROOT}" submodule update --init --recursive

MACOS_ROOT="${CLONE_ROOT}/src/platform/macos"
rm -rf "${CLONE_ROOT}/build" "${MACOS_ROOT}/Derived"
cd "${MACOS_ROOT}"
tuist generate --no-open

tuist xcodebuild test \
  -workspace Lumen.xcworkspace \
  -scheme LumenTuistTests \
  -destination 'platform=macOS' \
  -derivedDataPath "${SCRATCH}/test-derived" \
  -only-testing:LumenTuistTests/LumenPrivateDisplayControlTests \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES

rm -rf "${CLONE_ROOT}/build" "${SCRATCH}/canary-derived"

tuist xcodebuild build \
  -workspace Lumen.xcworkspace \
  -scheme LumenDisplayDisconnectCanary \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "${SCRATCH}/canary-derived" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES

printf 'cold_focused_test_build=passed commit=%s\n' "${COMMIT}"
printf 'cold_canary_build=passed commit=%s\n' "${COMMIT}"
