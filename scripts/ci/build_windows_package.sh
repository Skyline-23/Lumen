#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${LUMEN_WINDOWS_BUILD_DIR:-${REPO_ROOT}/cmake-build-release}"
STAGE_DIR="${BUILD_DIR}/msi-stage"
DRIVER_STAGE_DIR="${STAGE_DIR}/driver"
VERSION="${LUMEN_VERSION:-0.0.0}"
VERSION="${VERSION#v}"
ARTIFACT_VERSION="${LUMEN_ARTIFACT_VERSION:-${VERSION}}"
ARTIFACT_VERSION="${ARTIFACT_VERSION#v}"
DRIVER_PACKAGE_DIR="${LUMEN_WINDOWS_DRIVER_PACKAGE_DIR:-}"
COMPILER_LAUNCHER="${LUMEN_CMAKE_COMPILER_LAUNCHER:-}"
CMAKE_LAUNCHER_ARGUMENTS=()

if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "LUMEN_VERSION must use the form 1.2.3 (a leading v is allowed)." >&2
  exit 2
fi
if [[ ! "${ARTIFACT_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[1-9][0-9]*)?$ ]]; then
  echo "LUMEN_ARTIFACT_VERSION must use 1.2.3 or 1.2.3-beta.N." >&2
  exit 2
fi
if [[ -z "${DRIVER_PACKAGE_DIR}" || ! -d "${DRIVER_PACKAGE_DIR}" ]]; then
  echo "LUMEN_WINDOWS_DRIVER_PACKAGE_DIR must identify the built IDD package directory." >&2
  exit 2
fi
for driver_file in LumenIddCx.dll LumenIddCx.inf lumeniddcx.cat; do
  if [[ ! -f "${DRIVER_PACKAGE_DIR}/${driver_file}" ]]; then
    echo "Windows IDD package is missing ${driver_file}." >&2
    exit 2
  fi
done
if [[ -n "${COMPILER_LAUNCHER}" ]]; then
  if ! command -v "${COMPILER_LAUNCHER}" >/dev/null 2>&1; then
    echo "Requested CMake compiler launcher is unavailable: ${COMPILER_LAUNCHER}" >&2
    exit 2
  fi
  CMAKE_LAUNCHER_ARGUMENTS+=(
    "-DCMAKE_C_COMPILER_LAUNCHER=${COMPILER_LAUNCHER}"
    "-DCMAKE_CXX_COMPILER_LAUNCHER=${COMPILER_LAUNCHER}"
  )
fi

export BRANCH="${GITHUB_REF_NAME:-${BRANCH:-local}}"
export BUILD_VERSION="${VERSION}"
export COMMIT="${GITHUB_SHA:-${COMMIT:-unknown}}"
export RUSTFLAGS="${RUSTFLAGS:+${RUSTFLAGS} }-D warnings"

cmake \
  -S "${REPO_ROOT}" \
  -B "${BUILD_DIR}" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_PROCESSOR=AMD64 \
  -DBUILD_WERROR=ON \
  -DLUMEN_WINDOWS_DEVELOPER_BUILD=OFF \
  "${CMAKE_LAUNCHER_ARGUMENTS[@]}"

cmake --build "${BUILD_DIR}" --parallel
rm -rf "${STAGE_DIR}"
cmake --install "${BUILD_DIR}" --prefix "${STAGE_DIR}" --strip
mkdir -p "${DRIVER_STAGE_DIR}"
cp \
  "${DRIVER_PACKAGE_DIR}/LumenIddCx.dll" \
  "${DRIVER_PACKAGE_DIR}/LumenIddCx.inf" \
  "${DRIVER_PACKAGE_DIR}/lumeniddcx.cat" \
  "${DRIVER_STAGE_DIR}/"

PACKAGE_DIR="${BUILD_DIR}/cpack_artifacts"
WIX_OUTPUT_DIR="${BUILD_DIR}/wix-output"
WIX_INTERMEDIATE_DIR="${BUILD_DIR}/wix-obj"
OUTPUT_PACKAGE="${PACKAGE_DIR}/Lumen-${ARTIFACT_VERSION}-Windows-x86_64.msi"
rm -rf "${WIX_OUTPUT_DIR}" "${WIX_INTERMEDIATE_DIR}"
mkdir -p "${PACKAGE_DIR}" "${WIX_OUTPUT_DIR}"

dotnet build "${REPO_ROOT}/packaging/windows/Lumen.wixproj" \
  --configuration Release \
  --no-incremental \
  --property:StageDir="$(cygpath -w "${STAGE_DIR}")" \
  --property:ProductVersion="${VERSION}" \
  --property:BaseIntermediateOutputPath="$(cygpath -w "${WIX_INTERMEDIATE_DIR}")\\" \
  --property:OutputPath="$(cygpath -w "${WIX_OUTPUT_DIR}")"

SOURCE_PACKAGE="$(find "${WIX_OUTPUT_DIR}" -type f -name 'Lumen.msi' -print -quit)"
[[ -f "${SOURCE_PACKAGE}" ]] || {
  echo "Windows installer was not produced at ${SOURCE_PACKAGE}" >&2
  exit 1
}
rm -f "${OUTPUT_PACKAGE}"
mv -f "${SOURCE_PACKAGE}" "${OUTPUT_PACKAGE}"
echo "Created ${OUTPUT_PACKAGE}"
