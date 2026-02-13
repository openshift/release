#!/bin/bash
set -euo pipefail

source "${SHARED_DIR}/env"
echo "Using Bundle Image: ${BUNDLE_IMAGE}"
operator-sdk run bundle --timeout=10m -n openshift-kueue-operator "$BUNDLE_IMAGE" --security-context-config=restricted
echo "Kueue operator installed successfully"
