#!/bin/bash

set -euo pipefail

WORK_DIR="$(mktemp -d)"

# ---------------------------------------------------------------------------
# 1. Clone rosa-regional-platform (test harness + e2e-tests.sh runner)
# ---------------------------------------------------------------------------
# Use the pinned SHA from the provision step so all workflow steps run the
# same code. Fall back to ROSA_REGIONAL_PLATFORM_REF if no pin exists.
PINNED_SHA_FILE="${SHARED_DIR}/rosa-regional-platform-sha"
if [[ -r "${PINNED_SHA_FILE}" ]]; then
  CLONE_REF="$(cat "${PINNED_SHA_FILE}")"
  echo "Using pinned commit ${CLONE_REF} from provision step..."
else
  CLONE_REF="${ROSA_REGIONAL_PLATFORM_REF}"
  echo "No pinned commit found, cloning at ref ${CLONE_REF}..."
fi

git clone https://github.com/openshift-online/rosa-regional-platform.git "${WORK_DIR}/platform"
cd "${WORK_DIR}/platform"
git checkout "${CLONE_REF}"

# Set up AWS profiles from mounted credentials (backwards-compatible)
[[ -f ci/setup-aws-profiles.sh ]] && source ci/setup-aws-profiles.sh

# ---------------------------------------------------------------------------
# 2. Resolve which e2e test repo + ref to use
# ---------------------------------------------------------------------------
# Priority:
#   a) Explicit ROSA_REGIONAL_E2E_REF / ROSA_REGIONAL_E2E_REPO env vars
#   b) Auto-detect from PR context (rosa-regional-platform-api only):
#      fetch the fork's clone URL via GitHub API so fork PRs work too
#   c) Defaults: main branch of openshift-online/rosa-regional-platform-api
DEFAULT_E2E_REPO="https://github.com/openshift-online/rosa-regional-platform-api.git"

if [[ -n "${ROSA_REGIONAL_E2E_REF:-}" ]]; then
  export E2E_REF="${ROSA_REGIONAL_E2E_REF}"
  export E2E_REPO="${ROSA_REGIONAL_E2E_REPO:-${DEFAULT_E2E_REPO}}"
elif [[ "${REPO_NAME:-}" == "rosa-regional-platform-api" ]] && [[ -n "${PULL_NUMBER:-}" ]]; then
  E2E_REPO=$(curl -s "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/pulls/${PULL_NUMBER}" | jq -r '.head.repo.clone_url')
  export E2E_REPO
  export E2E_REF="${PULL_HEAD_REF}"
  echo "Auto-detected from ${REPO_NAME} PR #${PULL_NUMBER}:"
  echo "  E2E_REPO=${E2E_REPO}"
  echo "  E2E_REF=${E2E_REF}"
else
  export E2E_REPO="${DEFAULT_E2E_REPO}"
fi

# ---------------------------------------------------------------------------
# 3. Run e2e tests
# ---------------------------------------------------------------------------
echo "Running e2e tests..."
./ci/e2e-tests.sh
