#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CARGO_BIN="$(command -v cargo 2>/dev/null || true)"

if [[ -z "${CARGO_BIN}" && -x "${HOME}/.cargo/bin/cargo" ]]; then
  CARGO_BIN="${HOME}/.cargo/bin/cargo"
fi
if [[ -z "${CARGO_BIN}" ]]; then
  echo "error: cargo was not found in PATH or ~/.cargo/bin" >&2
  exit 1
fi

CONFIGURATION_NAME="${CONFIGURATION:-Debug}"
PROFILE="debug"
if [[ "${CONFIGURATION_NAME}" == "Release" ]]; then
  PROFILE="release"
fi

cd "${REPO_ROOT}"

REQUESTED_ARCHS="${CURRENT_ARCH:-}"
if [[ -z "${REQUESTED_ARCHS}" || "${REQUESTED_ARCHS}" == "undefined_arch" ]]; then
  REQUESTED_ARCHS="${ARCHS:-${NATIVE_ARCH_ACTUAL:-arm64}}"
fi

for ARCH in ${(z)REQUESTED_ARCHS}; do
  case "${ARCH}" in
    arm64)
      RUST_TARGET="aarch64-apple-darwin"
      ;;
    *)
      echo "error: Lumen for macOS supports Apple Silicon only; unsupported architecture: ${ARCH}" >&2
      exit 1
      ;;
  esac

  export CARGO_TARGET_DIR="${REPO_ROOT}/build/rust-target/${ARCH}"

  CARGO_ARGS=(build --locked --package lumen-engine --target "${RUST_TARGET}")
  if [[ "${CONFIGURATION_NAME}" == "Release" ]]; then
    CARGO_ARGS+=(--release)
  fi
  "${CARGO_BIN}" "${CARGO_ARGS[@]}"

  HOST_ARGS=(build --locked --package lumen-host --target "${RUST_TARGET}")
  if [[ "${CONFIGURATION_NAME}" == "Release" ]]; then
    HOST_ARGS+=(--release)
  fi
  "${CARGO_BIN}" "${HOST_ARGS[@]}"

  OUTPUT_DIR="${REPO_ROOT}/build/rust-engine/${CONFIGURATION_NAME}/${ARCH}"
  mkdir -p "${OUTPUT_DIR}"
  cp "${CARGO_TARGET_DIR}/${RUST_TARGET}/${PROFILE}/liblumen_engine.a" "${OUTPUT_DIR}/"
  cp "${CARGO_TARGET_DIR}/${RUST_TARGET}/${PROFILE}/liblumen_host.a" "${OUTPUT_DIR}/"
  cp "${CARGO_TARGET_DIR}/${RUST_TARGET}/${PROFILE}/lumen-host" "${OUTPUT_DIR}/LumenRustHostWorker"
done
