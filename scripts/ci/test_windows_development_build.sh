#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEVELOPMENT_BUILD="${REPO_ROOT}/scripts/windows/build_windows_development.sh"
RELEASE_BUILD="${REPO_ROOT}/scripts/ci/build_windows_package.sh"

output="$(bash "${DEVELOPMENT_BUILD}" --dry-run --component all)"

for required in \
  '-DLUMEN_WINDOWS_DEVELOPER_BUILD=ON' \
  'dotnet restore' \
  '--property:SelfContained=false' \
  '--property:WindowsAppSDKSelfContained=false' \
  '--target lumen lumen-service lumen-windows-ui'; do
  grep -F --quiet -- "${required}" <<<"${output}" || {
    echo "Development build dry-run is missing: ${required}" >&2
    exit 1
  }
done

for excluded in \
  'cmake --install' \
  'msi-stage' \
  'Lumen.wixproj' \
  'wix-output' \
  'vigembus_installer.exe'; do
  if grep -F --quiet -- "${excluded}" <<<"${output}"; then
    echo "Development build dry-run unexpectedly contains: ${excluded}" >&2
    exit 1
  fi
done

for required_release_step in \
  '-DLUMEN_WINDOWS_DEVELOPER_BUILD=OFF' \
  'cmake --install' \
  'msi-stage' \
  'Lumen.wixproj' \
  'wix-output'; do
  grep -F --quiet -- "${required_release_step}" "${RELEASE_BUILD}" || {
    echo "Release packaging contract is missing: ${required_release_step}" >&2
    exit 1
  }
done
