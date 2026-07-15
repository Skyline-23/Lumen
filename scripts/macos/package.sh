#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h}"
MACOS_ROOT="${REPO_ROOT}/src/platform/macos"
BUILD_ROOT="${LUMEN_BUILD_ROOT:-${REPO_ROOT}/build/macos-package}"
DERIVED_DATA="${BUILD_ROOT}/DerivedData"
OUTPUT_DIR="${LUMEN_OUTPUT_DIR:-${BUILD_ROOT}/artifacts}"
CONFIGURATION="${LUMEN_CONFIGURATION:-Release}"
SIGNING_IDENTITY="${LUMEN_SIGNING_IDENTITY:-Developer ID Application: Buseong Kim (Q23JLSJCCV)}"
DEVELOPMENT_TEAM="${LUMEN_DEVELOPMENT_TEAM:-Q23JLSJCCV}"
NOTARY_PROFILE="${LUMEN_NOTARY_PROFILE:-}"
ARCHS="${LUMEN_ARCHS:-arm64}"
VERSION_OVERRIDE="${LUMEN_VERSION:-}"
BUILD_NUMBER="${LUMEN_BUILD_NUMBER:-1}"
SKIP_TESTS=0
INSTALL_APPLICATION=0

usage() {
  cat <<'EOF'
Usage: scripts/macos/package.sh [--skip-tests] [--install] [--output DIR]

Environment:
  LUMEN_CONFIGURATION       Xcode configuration (default: Release)
  LUMEN_BUILD_ROOT          Temporary build directory
  LUMEN_OUTPUT_DIR          DMG output directory
  LUMEN_SIGNING_IDENTITY    Build signing identity (default: Buseong Kim Developer ID); use '-' for ad-hoc signing
  LUMEN_DEVELOPMENT_TEAM    Apple development team (default: Q23JLSJCCV)
  LUMEN_ARCHS               Build architectures (default: arm64)
  LUMEN_VERSION             Release version, with or without a leading v
  LUMEN_BUILD_NUMBER        Numeric bundle build version (default: 1)
  LUMEN_NOTARY_PROFILE      notarytool keychain profile; enables notarization
  LUMEN_INSTALL_DIR         Application install directory (default: /Applications)
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --skip-tests)
      SKIP_TESTS=1
      shift
      ;;
    --install)
      INSTALL_APPLICATION=1
      shift
      ;;
    --output)
      [[ $# -ge 2 ]] || { print -u2 "--output requires a directory"; exit 2; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      print -u2 "Unknown argument: $1"
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -n "${VERSION_OVERRIDE}" ]]; then
  VERSION_OVERRIDE="${VERSION_OVERRIDE#v}"
  [[ "${VERSION_OVERRIDE}" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || {
    print -u2 "LUMEN_VERSION must use the form 1.2.3 (a leading v is allowed)."
    exit 2
  }
fi
[[ "${BUILD_NUMBER}" =~ '^[0-9]+$' ]] || {
  print -u2 "LUMEN_BUILD_NUMBER must be numeric."
  exit 2
}

for command in tuist codesign hdiutil ditto; do
  command -v "${command}" >/dev/null || {
    print -u2 "Required command not found: ${command}"
    exit 1
  }
done

mkdir -p "${BUILD_ROOT}" "${OUTPUT_DIR}"

OPUS_ARCHIVE="${LUMEN_OPUS_ARCHIVE:-${REPO_ROOT}/third-party/runtime-deps/dist/Darwin-arm64/lib/libopus.a}"
if [[ ! -f "${OPUS_ARCHIVE}" ]] && command -v brew >/dev/null; then
  HOMEBREW_OPUS_PREFIX="$(brew --prefix opus 2>/dev/null || true)"
  if [[ -n "${HOMEBREW_OPUS_PREFIX}" ]]; then
    OPUS_ARCHIVE="${HOMEBREW_OPUS_PREFIX}/lib/libopus.a"
  fi
fi
[[ -f "${OPUS_ARCHIVE}" ]] || {
  print -u2 "Static Opus archive not found. Install opus with Homebrew or set LUMEN_OPUS_ARCHIVE."
  exit 1
}
export LUMEN_OPUS_ARCHIVE="${OPUS_ARCHIVE}"
export TUIST_LUMEN_OPUS_ARCHIVE="${OPUS_ARCHIVE}"

print "Generating Lumen macOS workspace..."
(cd "${MACOS_ROOT}" && tuist generate --no-open)

if (( SKIP_TESTS == 0 )); then
  print "Building the Debug Rust engine for macOS tests..."
  CONFIGURATION=Debug \
  ARCHS="${ARCHS}" \
  CURRENT_ARCH=undefined_arch \
    "${REPO_ROOT}/scripts/rust/build_lumen_engine.sh"

  print "Running macOS tests..."
  (cd "${MACOS_ROOT}" && tuist test LumenTuistTests \
    --no-selective-testing \
    --no-upload \
    -- \
    -derivedDataPath "${DERIVED_DATA}" \
    CODE_SIGNING_ALLOWED=NO)

  print "Regenerating the complete macOS workspace after focused tests..."
  (cd "${MACOS_ROOT}" && tuist generate --no-open)
fi

print "Building the ${CONFIGURATION} Rust engine..."
CONFIGURATION="${CONFIGURATION}" \
ARCHS="${ARCHS}" \
CURRENT_ARCH=undefined_arch \
  "${REPO_ROOT}/scripts/rust/build_lumen_engine.sh"

build_arguments=(
  -workspace "${MACOS_ROOT}/Lumen.xcworkspace"
  -scheme LumenApp
  -configuration "${CONFIGURATION}"
  -destination 'generic/platform=macOS'
  -derivedDataPath "${DERIVED_DATA}"
  "ARCHS=${ARCHS}"
  "CURRENT_PROJECT_VERSION=${BUILD_NUMBER}"
)

architecture_list=(${(z)ARCHS})
if (( ${#architecture_list} > 1 )); then
  build_arguments+=(ONLY_ACTIVE_ARCH=NO)
else
  build_arguments+=(ONLY_ACTIVE_ARCH=YES)
fi
if [[ -n "${VERSION_OVERRIDE}" ]]; then
  build_arguments+=("MARKETING_VERSION=${VERSION_OVERRIDE}")
fi

if [[ "${SIGNING_IDENTITY}" == '-' ]]; then
  build_arguments+=(CODE_SIGNING_ALLOWED=NO)
else
  build_arguments+=(
    CODE_SIGNING_ALLOWED=YES
    CODE_SIGN_STYLE=Manual
    "CODE_SIGN_IDENTITY=${SIGNING_IDENTITY}"
    "DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}"
  )
fi
print "Building Lumen.app..."
(cd "${MACOS_ROOT}" && tuist xcodebuild build "${build_arguments[@]}")

SOURCE_APP="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/Lumen.app"
[[ -d "${SOURCE_APP}" ]] || {
  print -u2 "Lumen.app was not produced at ${SOURCE_APP}"
  exit 1
}

VERSION="${VERSION_OVERRIDE}"
if [[ -z "${VERSION}" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${SOURCE_APP}/Contents/Info.plist" 2>/dev/null || true)"
fi
if [[ -z "${VERSION}" || "${VERSION}" == '0.0.0' ]]; then
  VERSION="$(git -C "${REPO_ROOT}" describe --tags --always --dirty | tr '/' '-')"
fi

STAGING_ROOT="${BUILD_ROOT}/dmg-root"
STAGED_APP="${STAGING_ROOT}/Lumen.app"
DMG_PATH="${OUTPUT_DIR}/Lumen-${VERSION}-macOS.dmg"
rm -rf "${STAGING_ROOT}" "${DMG_PATH}"
mkdir -p "${STAGING_ROOT}"
ditto "${SOURCE_APP}" "${STAGED_APP}"

if [[ "${SIGNING_IDENTITY}" == '-' ]]; then
  print "Applying ad-hoc signature for local installation..."
  codesign --force --deep --sign - "${STAGED_APP}"
else
  print "Preserving build-time signature from ${SIGNING_IDENTITY}."
fi

codesign --verify --deep --strict --verbose=2 "${STAGED_APP}"
ln -s /Applications "${STAGING_ROOT}/Applications"

if (( INSTALL_APPLICATION == 1 )); then
  INSTALL_DIR="${LUMEN_INSTALL_DIR:-/Applications}"
  INSTALL_DESTINATION="${INSTALL_DIR}/Lumen.app"
  INSTALL_TEMPORARY="${INSTALL_DIR}/.Lumen.installing.app"

  print "Installing ${INSTALL_DESTINATION}..."
  mkdir -p "${INSTALL_DIR}"
  pkill -x Lumen >/dev/null 2>&1 || true
  pkill -x LumenHostWorker >/dev/null 2>&1 || true
  for _ in {1..40}; do
    if ! pgrep -x Lumen >/dev/null 2>&1 && ! pgrep -x LumenHostWorker >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  if pgrep -x Lumen >/dev/null 2>&1 || pgrep -x LumenHostWorker >/dev/null 2>&1; then
    print -u2 "Existing Lumen processes did not stop before installation."
    exit 1
  fi
  rm -rf "${INSTALL_TEMPORARY}"
  ditto "${STAGED_APP}" "${INSTALL_TEMPORARY}"
  codesign --verify --deep --strict --verbose=2 "${INSTALL_TEMPORARY}"
  rm -rf "${INSTALL_DESTINATION}"
  mv "${INSTALL_TEMPORARY}" "${INSTALL_DESTINATION}"
  open -na "${INSTALL_DESTINATION}"
fi

print "Creating ${DMG_PATH}..."
hdiutil create \
  -volname "Lumen" \
  -srcfolder "${STAGING_ROOT}" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "${DMG_PATH}"

if [[ "${SIGNING_IDENTITY}" != '-' ]]; then
  codesign --force --timestamp --sign "${SIGNING_IDENTITY}" "${DMG_PATH}"
  codesign --verify --verbose=2 "${DMG_PATH}"
fi

if [[ -n "${NOTARY_PROFILE}" ]]; then
  [[ "${SIGNING_IDENTITY}" != '-' ]] || {
    print -u2 "LUMEN_NOTARY_PROFILE requires a Developer ID signing identity."
    exit 1
  }
  print "Submitting DMG for notarization..."
  xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
  xcrun stapler staple "${DMG_PATH}"
  xcrun stapler validate "${DMG_PATH}"
fi

print "Created ${DMG_PATH}"
