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
tuist generate --no-open --path "${MACOS_ROOT}"

xcodebuild test \
  -workspace "${MACOS_ROOT}/Lumen.xcworkspace" \
  -scheme LumenTuistTests \
  -destination 'platform=macOS' \
  -derivedDataPath "${SCRATCH}/test-derived" \
  -only-testing:LumenTuistTests/LumenPrivateDisplayControlTests \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO

rm -rf "${CLONE_ROOT}/build" "${SCRATCH}/canary-derived"

xcodebuild build \
  -workspace "${MACOS_ROOT}/Lumen.xcworkspace" \
  -scheme LumenDisplayDisconnectCanary \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "${SCRATCH}/canary-derived" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO

printf 'cold_focused_test_build=passed commit=%s\n' "${COMMIT}"
printf 'cold_canary_build=passed commit=%s\n' "${COMMIT}"
