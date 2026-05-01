#!/bin/bash

set -euo pipefail

echo "=== HyperFleet Commit Message Validation ==="

if [ -z "${PULL_BASE_SHA:-}" ]; then
    echo "ERROR: PULL_BASE_SHA is not set; presubmit checks must run in PR context."
    exit 1
fi

HOOKS_VERSION="v0.1.2"
HOOKS_URL="https://github.com/openshift-hyperfleet/hyperfleet-hooks/releases/download/${HOOKS_VERSION}/hyperfleet-hooks-linux-amd64"
HOOKS_BIN="/tmp/hyperfleet-hooks"

echo "Downloading hyperfleet-hooks ${HOOKS_VERSION}..."
curl -fsSL -o "${HOOKS_BIN}" "${HOOKS_URL}"
chmod +x "${HOOKS_BIN}"
export PATH="/tmp:$PATH"

echo "Running commitlint validation..."
hyperfleet-hooks commitlint --pr
