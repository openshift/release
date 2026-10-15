#!/bin/bash

set -euo pipefail

WORK_DIR="$(mktemp -d)"

# ---------------------------------------------------------------------------
# 1. Clone rosa-hyperfleet (test harness + e2e-tests.sh runner)
# ---------------------------------------------------------------------------
# Use the pinned SHA from the provision step so all workflow steps run the
# same code. Fall back to ROSA_REGIONAL_PLATFORM_REF if no pin exists.
PINNED_SHA_FILE="${SHARED_DIR}/rosa-hyperfleet-sha"
if [[ -r "${PINNED_SHA_FILE}" ]]; then
  CLONE_REF="$(cat "${PINNED_SHA_FILE}")"
  echo "Using pinned commit ${CLONE_REF} from provision step..."
else
  CLONE_REF="${ROSA_REGIONAL_PLATFORM_REF}"
  echo "No pinned commit found, cloning at ref ${CLONE_REF}..."
fi

git clone https://github.com/openshift-online/rosa-hyperfleet.git "${WORK_DIR}/platform"
cd "${WORK_DIR}/platform"
git checkout "${CLONE_REF}"

# ---------------------------------------------------------------------------
# 2. Resolve which e2e test repo + ref to use
# ---------------------------------------------------------------------------
# Priority, for the api tests (E2E_*) and likewise the zoa tests (ZOA_*) below:
#   a) Explicit ROSA_REGIONAL_E2E_REF / ROSA_REGIONAL_E2E_REPO env vars
#   b) PR context: a PR of the tests' own repo, merged into its base
#   c) Defaults: main branch of openshift-online/rosa-hyperfleet-api
DEFAULT_E2E_REPO="https://github.com/openshift-online/rosa-hyperfleet-api.git"

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

if [[ -n "${ROSA_REGIONAL_E2E_REF:-}" ]]; then
  export E2E_REF="${ROSA_REGIONAL_E2E_REF}"
  export E2E_REPO="${ROSA_REGIONAL_E2E_REPO:-${DEFAULT_E2E_REPO}}"
elif [[ "${REPO_NAME:-}" == "rosa-hyperfleet-api" ]] && [[ -n "${PULL_NUMBER:-}" ]]; then
  checkout_merged_pr "${WORK_DIR}/e2e-src"
  export E2E_REPO="file://${WORK_DIR}/e2e-src" E2E_REF="e2e-under-test"
else
  export E2E_REPO="${DEFAULT_E2E_REPO}"
fi

# Same for rosa-hyperfleet-zoa (ZOA e2e tests live in the zoa repo)
if [[ -n "${ROSA_REGIONAL_ZOA_REF:-}" ]]; then
  export ZOA_REF="${ROSA_REGIONAL_ZOA_REF}"
  export ZOA_REPO="${ROSA_REGIONAL_ZOA_REPO:-https://github.com/openshift-online/rosa-hyperfleet-zoa.git}"
elif [[ "${REPO_NAME:-}" == "rosa-hyperfleet-zoa" ]] && [[ -n "${PULL_NUMBER:-}" ]]; then
  checkout_merged_pr "${WORK_DIR}/zoa-src"
  export ZOA_REPO="file://${WORK_DIR}/zoa-src" ZOA_REF="e2e-under-test"
fi

# ---------------------------------------------------------------------------
# 3. Export test control variables and run e2e tests
# ---------------------------------------------------------------------------
# Pass through test skip flags
export E2E_SKIP_PLATFORM_API="${E2E_SKIP_PLATFORM_API:-false}"
export E2E_SKIP_HCP="${E2E_SKIP_HCP:-false}"
export E2E_SKIP_MONITORING="${E2E_SKIP_MONITORING:-false}"
export E2E_SKIP_ROSA_CLI="${E2E_SKIP_ROSA_CLI:-true}"

# Pass label filter if specified
if [[ -n "${ROSA_LABEL_FILTER:-}" ]]; then
  export ROSA_LABEL_FILTER="${ROSA_LABEL_FILTER}"
fi

# OCP release image for the e2e HCP cluster (empty uses the default).
# An explicit OCP_IMAGE wins over one resolved by rosa-hyperfleet-resolve-ocp-image.
RESOLVED_OCP_IMAGE_FILE="${SHARED_DIR}/ocp-image"
if [[ -z "${OCP_IMAGE:-}" ]] && [[ -r "${RESOLVED_OCP_IMAGE_FILE}" ]]; then
  OCP_IMAGE="$(cat "${RESOLVED_OCP_IMAGE_FILE}")"
fi
export OCP_IMAGE="${OCP_IMAGE:-}"

echo "Running e2e tests..."
./ci/e2e-tests.sh
