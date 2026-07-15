#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${LUMEN_WINDOWS_BUILD_DIR:-${REPO_ROOT}/cmake-build-release}"
VERSION="${LUMEN_VERSION:-0.0.0}"
VERSION="${VERSION#v}"

if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "LUMEN_VERSION must use the form 1.2.3 (a leading v is allowed)." >&2
  exit 2
fi

export BRANCH="${GITHUB_REF_NAME:-${BRANCH:-local}}"
export BUILD_VERSION="${VERSION}"
export COMMIT="${GITHUB_SHA:-${COMMIT:-unknown}}"

cmake \
  -S "${REPO_ROOT}" \
  -B "${BUILD_DIR}" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_PROCESSOR=AMD64

cmake --build "${BUILD_DIR}" --parallel
cpack --config "${BUILD_DIR}/CPackConfig.cmake" -G NSIS

PACKAGE_DIR="${BUILD_DIR}/cpack_artifacts"
SOURCE_PACKAGE="${PACKAGE_DIR}/Lumen.exe"
OUTPUT_PACKAGE="${PACKAGE_DIR}/Lumen-${VERSION}-Windows-x86_64.exe"
[[ -f "${SOURCE_PACKAGE}" ]] || {
  echo "Windows installer was not produced at ${SOURCE_PACKAGE}" >&2
  exit 1
}
mv -f "${SOURCE_PACKAGE}" "${OUTPUT_PACKAGE}"
echo "Created ${OUTPUT_PACKAGE}"
