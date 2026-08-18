#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Review Responder Eval Cleanup ==="

# Disable tracing while loading secret
set +x
GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token" 2>/dev/null || echo "")
export GITHUB_TOKEN

if [[ -z "${GITHUB_TOKEN}" ]]; then
    echo "No token available, skipping cleanup."
    exit 0
fi

prow-agent-eval-python cleanup \
    --shared-dir="${SHARED_DIR}" || true

echo "=== TRT Review Responder Eval Cleanup Complete ==="
