#!/bin/bash

set -euo pipefail

WORK_DIR="$(mktemp -d)"

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
# the PR branch after provisioning doesn't lose it. If it can't be fetched,
# tear down with main anyway rather than leave the environment running.
git init -q "${WORK_DIR}/platform"
cd "${WORK_DIR}/platform"
if ! git fetch -q --depth 1 "${REPOSITORY_URL}" "${CLONE_REF}"; then
  echo "WARNING: could not fetch ${CLONE_REF} from ${REPOSITORY_URL}; tearing down with openshift-online/rosa-hyperfleet@main" >&2
  git fetch -q --depth 1 https://github.com/openshift-online/rosa-hyperfleet.git main
fi
git checkout -q FETCH_HEAD

if [[ "${ROSA_REGIONAL_TEARDOWN_FIRE_AND_FORGET:-true}" == "true" ]]; then
  echo "Starting ephemeral teardown (fire-and-forget)..."
  uv run --no-cache ci/ephemeral-provider/main.py --teardown-fire-and-forget
else
  echo "Starting ephemeral teardown (synchronous)..."
  uv run --no-cache ci/ephemeral-provider/main.py --teardown
fi
