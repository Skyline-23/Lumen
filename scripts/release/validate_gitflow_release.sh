#!/usr/bin/env bash
set -euo pipefail

TAG="${LUMEN_RELEASE_TAG:-${GITHUB_REF_NAME:-}}"
RELEASE_SHA="${LUMEN_RELEASE_SHA:-${GITHUB_SHA:-}}"
REMOTE="${LUMEN_RELEASE_REMOTE:-origin}"
OUTPUT_PATH="${GITHUB_OUTPUT:-}"

fail() {
  echo "$*" >&2
  exit 1
}

validate_beta_history() {
  local excluded_tag="$1"
  local ancestor_sha="$2"
  local expected_number=1
  local existing_number
  local existing_tag

  BETA_HISTORY_COUNT=0
  LATEST_BETA_TAG=""
  while IFS= read -r existing_tag; do
    [[ -n "${existing_tag}" ]] || continue
    [[ "${existing_tag}" != "${excluded_tag}" ]] || continue
    [[ "${existing_tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-beta\.([1-9][0-9]*)$ ]] || continue
    existing_number="${BASH_REMATCH[1]}"
    (( existing_number == expected_number )) || {
      fail "Beta history for ${PRODUCT_VERSION} is not contiguous; expected beta.${expected_number}, found ${existing_tag}."
    }
    [[ "$(git cat-file -t "${existing_tag}")" == "tag" ]] || {
      fail "Earlier beta ${existing_tag} must be annotated."
    }
    git merge-base --is-ancestor "${existing_tag}^{commit}" "${ancestor_sha}" || {
      fail "Earlier beta ${existing_tag} is not an ancestor of ${ancestor_sha}."
    }
    BETA_HISTORY_COUNT="${existing_number}"
    LATEST_BETA_TAG="${existing_tag}"
    expected_number=$((expected_number + 1))
  done < <(git tag --list "v${PRODUCT_VERSION}-beta.*" --sort=version:refname)
}

[[ -n "${TAG}" ]] || fail "LUMEN_RELEASE_TAG or GITHUB_REF_NAME is required."
[[ -n "${RELEASE_SHA}" ]] || fail "LUMEN_RELEASE_SHA or GITHUB_SHA is required."
[[ "${TAG}" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(-beta\.([1-9][0-9]*))?$ ]] || {
  fail "Release tag must use v1.2.3 or v1.2.3-beta.N: ${TAG}"
}

PRODUCT_VERSION="${BASH_REMATCH[1]}"
RELEASE_VERSION="${TAG#v}"
BETA_NUMBER="${BASH_REMATCH[3]:-}"
RELEASE_BRANCH="release/${PRODUCT_VERSION}"
REMOTE_RELEASE_REF="refs/remotes/${REMOTE}/${RELEASE_BRANCH}"

git fetch --force --tags "${REMOTE}"
git fetch --force --no-tags \
  "${REMOTE}" \
  "refs/heads/${RELEASE_BRANCH}:${REMOTE_RELEASE_REF}" || {
  fail "Required Git Flow branch is missing: ${REMOTE}/${RELEASE_BRANCH}"
}
TAG_SHA="$(git rev-parse "${TAG}^{commit}")"
RELEASE_SHA="$(git rev-parse "${RELEASE_SHA}^{commit}")"
BRANCH_SHA="$(git rev-parse "${REMOTE_RELEASE_REF}^{commit}")"
[[ "${TAG_SHA}" == "${RELEASE_SHA}" ]] || {
  fail "Release tag ${TAG} does not resolve to the triggering commit ${RELEASE_SHA}."
}
[[ "$(git cat-file -t "${TAG}")" == "tag" ]] || {
  fail "Release tag ${TAG} must be annotated."
}

ENGINE_VERSION="$(
  python3 -c \
    'import sys, tomllib; print(tomllib.load(open(sys.argv[1], "rb"))["package"]["version"])' \
    engine/lumen-engine/Cargo.toml
)"
HOST_VERSION="$(
  python3 -c \
    'import sys, tomllib; print(tomllib.load(open(sys.argv[1], "rb"))["package"]["version"])' \
    engine/lumen-host/Cargo.toml
)"
[[ "${ENGINE_VERSION}" == "${HOST_VERSION}" ]] || {
  fail "Lumen crate versions must match: engine=${ENGINE_VERSION}, host=${HOST_VERSION}"
}
[[ "${HOST_VERSION}" == "${PRODUCT_VERSION}" ]] || {
  fail "Release tag ${TAG} does not match product version ${HOST_VERSION}."
}

PRERELEASE=false
if [[ -n "${BETA_NUMBER}" ]]; then
  PRERELEASE=true
  [[ "${RELEASE_SHA}" == "${BRANCH_SHA}" ]] || {
    fail "Beta tag ${TAG} must point at the current ${REMOTE}/${RELEASE_BRANCH} head."
  }

  validate_beta_history "${TAG}" "${RELEASE_SHA}"
  EXPECTED_BETA=$((BETA_HISTORY_COUNT + 1))
  (( BETA_NUMBER == EXPECTED_BETA )) || {
    fail "Beta tag ${TAG} is out of sequence; expected v${PRODUCT_VERSION}-beta.${EXPECTED_BETA}."
  }
else
  git fetch --force --no-tags \
    "${REMOTE}" \
    "refs/heads/main:refs/remotes/${REMOTE}/main" \
    "refs/heads/develop:refs/remotes/${REMOTE}/develop"
  MAIN_SHA="$(git rev-parse "refs/remotes/${REMOTE}/main^{commit}")"
  DEVELOP_SHA="$(git rev-parse "refs/remotes/${REMOTE}/develop^{commit}")"

  [[ "${RELEASE_SHA}" == "${MAIN_SHA}" ]] || {
    fail "Stable tag ${TAG} must point at the current ${REMOTE}/main head."
  }
  STABLE_COMMIT_LINE="$(git rev-list --parents -n 1 "${RELEASE_SHA}")"
  read -r -a STABLE_COMMIT_PARTS <<< "${STABLE_COMMIT_LINE}"
  RELEASE_IS_PARENT=false
  for PARENT_SHA in "${STABLE_COMMIT_PARTS[@]:1}"; do
    if [[ "${PARENT_SHA}" == "${BRANCH_SHA}" ]]; then
      RELEASE_IS_PARENT=true
      break
    fi
  done
  [[ "${RELEASE_IS_PARENT}" == "true" ]] || {
    fail "Stable tag ${TAG} must point at a no-ff merge of ${REMOTE}/${RELEASE_BRANCH}."
  }
  git merge-base --is-ancestor "${BRANCH_SHA}" "${DEVELOP_SHA}" || {
    fail "${REMOTE}/${RELEASE_BRANCH} must be merged back into ${REMOTE}/develop before ${TAG}."
  }

  validate_beta_history "" "${BRANCH_SHA}"
  [[ -n "${LATEST_BETA_TAG}" ]] || {
    fail "Stable tag ${TAG} requires at least one published beta from ${RELEASE_BRANCH}."
  }
fi

OUTPUT_LINES=(
  "tag=${TAG}"
  "product_version=${PRODUCT_VERSION}"
  "release_version=${RELEASE_VERSION}"
  "prerelease=${PRERELEASE}"
  "release_branch=${RELEASE_BRANCH}"
)
if [[ -n "${OUTPUT_PATH}" ]]; then
  printf '%s\n' "${OUTPUT_LINES[@]}" >> "${OUTPUT_PATH}"
else
  printf '%s\n' "${OUTPUT_LINES[@]}"
fi
