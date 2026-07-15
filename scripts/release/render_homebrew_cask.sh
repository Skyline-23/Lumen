#!/bin/zsh
set -euo pipefail

if (( $# != 3 )); then
  print -u2 "Usage: scripts/release/render_homebrew_cask.sh VERSION DMG OUTPUT"
  exit 2
fi

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h}"
VERSION="${1#v}"
DMG_PATH="${2:A}"
OUTPUT_PATH="${3:A}"
TEMPLATE="${REPO_ROOT}/packaging/homebrew/Casks/lumen.rb.template"

[[ "${VERSION}" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || {
  print -u2 "Version must use the form 1.2.3 (a leading v is allowed)."
  exit 2
}
[[ -f "${DMG_PATH}" ]] || {
  print -u2 "DMG not found: ${DMG_PATH}"
  exit 1
}

SHA256="$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"
mkdir -p "${OUTPUT_PATH:h}"
sed \
  -e "s/@VERSION@/${VERSION}/g" \
  -e "s/@SHA256@/${SHA256}/g" \
  "${TEMPLATE}" > "${OUTPUT_PATH}"

print "Rendered ${OUTPUT_PATH}"
