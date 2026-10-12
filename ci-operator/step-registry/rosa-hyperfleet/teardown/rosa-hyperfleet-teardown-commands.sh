#!/bin/bash

set -euo pipefail

WORK_DIR="$(mktemp -d)"

# Use pinned SHA from provision step to ensure all steps use the same code
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

if [[ "${ROSA_REGIONAL_TEARDOWN_FIRE_AND_FORGET:-true}" == "true" ]]; then
  echo "Starting ephemeral teardown (fire-and-forget)..."
  uv run --no-cache ci/ephemeral-provider/main.py --teardown-fire-and-forget
else
  echo "Starting ephemeral teardown (synchronous)..."
  uv run --no-cache ci/ephemeral-provider/main.py --teardown
fi
