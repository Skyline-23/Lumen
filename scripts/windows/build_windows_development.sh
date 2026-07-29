#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${LUMEN_WINDOWS_DEV_BUILD_DIR:-${REPO_ROOT}/cmake-build-windows-dev}"
CONFIGURATION="${LUMEN_WINDOWS_DEV_CONFIGURATION:-Debug}"
UI_PROJECT="${REPO_ROOT}/src/platform/windows/Lumen.App/Lumen.App.csproj"
COMPONENT="all"
DRY_RUN=0

if [[ -n "${USERPROFILE:-}" ]] && command -v cygpath >/dev/null 2>&1; then
  WINDOWS_USER_CARGO_BIN="$(cygpath -u "${USERPROFILE}")/.cargo/bin"
  if [[ -d "${WINDOWS_USER_CARGO_BIN}" ]]; then
    export PATH="${WINDOWS_USER_CARGO_BIN}:${PATH}"
  fi
fi
if command -v cygpath >/dev/null 2>&1; then
  WINDOWS_PROGRAM_FILES="${ProgramFiles:-C:\Program Files}"
  WINDOWS_DOTNET_BIN="$(cygpath -u "${WINDOWS_PROGRAM_FILES}\dotnet")"
  if [[ -d "${WINDOWS_DOTNET_BIN}" ]]; then
    export PATH="${WINDOWS_DOTNET_BIN}:${PATH}"
  fi
fi

usage() {
  cat <<'USAGE'
Usage: scripts/windows/build_windows_development.sh [--component NAME] [--dry-run]

Build an incremental Windows development target without publishing, staging,
signing, drivers, or MSI creation. NAME is one of: all, host, service,
session-agent, ui. The default is all.

Environment:
  LUMEN_WINDOWS_DEV_BUILD_DIR       CMake/Ninja/Cargo build directory
  LUMEN_WINDOWS_DEV_CONFIGURATION   Debug, Release, or RelWithDebInfo (default: Debug)
USAGE
}

run() {
  if (( DRY_RUN )); then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    return
  fi
  "$@"
}

while (( $# )); do
  case "$1" in
    --component)
      (( $# >= 2 )) || { echo "--component requires a value" >&2; exit 2; }
      COMPONENT="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "${CONFIGURATION}" in
  Debug|Release|RelWithDebInfo) ;;
  *)
    echo "LUMEN_WINDOWS_DEV_CONFIGURATION must be Debug, Release, or RelWithDebInfo." >&2
    exit 2
    ;;
esac

case "${COMPONENT}" in
  all|host|service|session-agent|ui) ;;
  *)
    echo "Unknown development component: ${COMPONENT}" >&2
    usage >&2
    exit 2
    ;;
esac

if (( ! DRY_RUN )); then
  for required_tool in cmake cargo dotnet ninja; do
    command -v "${required_tool}" >/dev/null 2>&1 || {
      echo "Windows development build requires ${required_tool} on PATH." >&2
      exit 2
    }
  done
fi

run cmake \
  -S "${REPO_ROOT}" \
  -B "${BUILD_DIR}" \
  -G Ninja \
  "-DCMAKE_BUILD_TYPE=${CONFIGURATION}" \
  -DLUMEN_WINDOWS_DEVELOPER_BUILD=ON

if [[ "${COMPONENT}" == "all" || "${COMPONENT}" == "ui" ]]; then
  # Keep package downloads in the normal NuGet cache and make the subsequent
  # CMake target a no-restore, framework-dependent incremental build.
  run dotnet restore "${UI_PROJECT}" \
    --runtime win-x64 \
    --property:SelfContained=false \
    --property:WindowsAppSDKSelfContained=false
fi

case "${COMPONENT}" in
  all)
    run cmake --build "${BUILD_DIR}" --parallel --target lumen lumen-service lumen-windows-ui
    ;;
  host)
    run cmake --build "${BUILD_DIR}" --parallel --target lumen_host_rust_build
    ;;
  service)
    run cmake --build "${BUILD_DIR}" --parallel --target lumen-service
    ;;
  session-agent)
    run cmake --build "${BUILD_DIR}" --parallel --target lumen
    ;;
  ui)
    run cmake --build "${BUILD_DIR}" --parallel --target lumen-windows-ui
    ;;
esac
