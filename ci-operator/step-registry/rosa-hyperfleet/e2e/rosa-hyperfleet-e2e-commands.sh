#!/bin/bash

set -euo pipefail

WORK_DIR="$(mktemp -d)"

# ---------------------------------------------------------------------------
# 1. Clone rosa-hyperfleet (test harness + e2e-tests.sh runner)
# ---------------------------------------------------------------------------
# Use the repo, branch and commit pinned by the provision step so all workflow
# steps run the same code (the PR's own code on a rosa-hyperfleet PR). Fall back
# to ROSA_REGIONAL_PLATFORM_REF of openshift-online/rosa-hyperfleet otherwise.
SOURCE_ENV="${SHARED_DIR}/rosa-hyperfleet-source.env"
if [[ -r "${SOURCE_ENV}" ]]; then
  # shellcheck source=/dev/null
  source "${SOURCE_ENV}"
  CLONE_REF="${PINNED_SHA}"
  echo "Using pinned ${REPOSITORY_URL}@${CLONE_REF} from provision step..."
else
  export REPOSITORY_URL="https://github.com/openshift-online/rosa-hyperfleet.git"
  export REPOSITORY_BRANCH="${ROSA_REGIONAL_PLATFORM_REF}"
  CLONE_REF="${ROSA_REGIONAL_PLATFORM_REF}"
  echo "No pinned commit found, cloning at ref ${CLONE_REF}..."
fi

# Fetch the commit itself rather than cloning the branch, so a force-push to
# the PR branch after provisioning doesn't lose it.
git init -q "${WORK_DIR}/platform"
cd "${WORK_DIR}/platform"
git fetch -q --depth 1 "${REPOSITORY_URL}" "${CLONE_REF}"
git checkout -q FETCH_HEAD

# ---------------------------------------------------------------------------
# 2. On a PR of a repo holding e2e tests, run that PR's tests
# ---------------------------------------------------------------------------
# The api tests (E2E_*) live in rosa-hyperfleet-api and the ZOA tests (ZOA_*)
# in rosa-hyperfleet-zoa. On a PR of either, its tests run from the PR merged
# into its base, the source the images under test are built from. Otherwise
# ci/e2e-tests.sh uses the main branch of both repos.

# Checks out the PR merged into its base, the same source ci-operator builds
# the images under test from, on local branch "e2e-under-test" in $1.
# ci/e2e-tests.sh clones by branch name, so callers clone it via file://$1.
# refs/pull/N/head lives on the upstream repo, so fork PRs work too.
checkout_merged_pr() {
  git init -q "$1"
  git -C "$1" fetch -q --no-tags "https://github.com/${REPO_OWNER}/${REPO_NAME}.git" \
    "refs/heads/${PULL_BASE_REF}" "refs/pull/${PULL_NUMBER}/head"
  git -C "$1" checkout -q -b e2e-under-test "${PULL_BASE_SHA}"
  git -C "$1" -c user.name=ci -c user.email=ci@openshift.io \
    merge -q --no-ff --no-edit "${PULL_PULL_SHA}"
  echo "Testing ${REPO_NAME} PR #${PULL_NUMBER} (${PULL_PULL_SHA}) merged into ${PULL_BASE_REF} (${PULL_BASE_SHA})"
}

if [[ -n "${PULL_NUMBER:-}" ]]; then
  case "${REPO_NAME:-}" in
    rosa-hyperfleet-api)
      checkout_merged_pr "${WORK_DIR}/e2e-src"
      export E2E_REPO="file://${WORK_DIR}/e2e-src" E2E_REF="e2e-under-test"
      ;;
    rosa-hyperfleet-zoa)
      checkout_merged_pr "${WORK_DIR}/zoa-src"
      export ZOA_REPO="file://${WORK_DIR}/zoa-src" ZOA_REF="e2e-under-test"
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# 3. Run e2e tests
# ---------------------------------------------------------------------------
# E2E_SKIP_* and ROSA_LABEL_FILTER reach ci/e2e-tests.sh as step env vars.

# OCP release image for the e2e HCP cluster (empty uses the default).
# An explicit OCP_IMAGE wins over one resolved by rosa-hyperfleet-resolve-ocp-image.
RESOLVED_OCP_IMAGE_FILE="${SHARED_DIR}/ocp-image"
if [[ -z "${OCP_IMAGE:-}" ]] && [[ -r "${RESOLVED_OCP_IMAGE_FILE}" ]]; then
  OCP_IMAGE="$(cat "${RESOLVED_OCP_IMAGE_FILE}")"
fi
export OCP_IMAGE="${OCP_IMAGE:-}"

echo "Running e2e tests..."
./ci/e2e-tests.sh
