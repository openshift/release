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

TEARDOWN_ARGS=()
if [[ "${ROSA_REGIONAL_TEARDOWN_FIRE_AND_FORGET:-true}" == "true" ]]; then
  echo "Starting ephemeral teardown (fire-and-forget)..."
  TEARDOWN_ARGS+=(--teardown-fire-and-forget)
else
  echo "Starting ephemeral teardown (synchronous)..."
  TEARDOWN_ARGS+=(--teardown)
  if [[ "${ROSA_REGIONAL_TEARDOWN_NO_WAIT:-false}" == "true" ]]; then
    echo "  --no-wait: skipping pipeline completion wait"
    TEARDOWN_ARGS+=(--no-wait)
  fi
fi

uv run --no-cache ci/ephemeral-provider/main.py "${TEARDOWN_ARGS[@]}"
