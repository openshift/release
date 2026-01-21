#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Waiting for Konflux installation to be ready..."

# Wait for the Konflux CR to have Ready condition
# Timeout: 10 minutes as per konflux-ci/konflux-ci operator documentation
if ! oc wait --for=condition=Ready=True konflux konflux --timeout=10m; then
    echo "ERROR: Konflux installation did not become ready within timeout"
    echo "Current Konflux CR status:"
    oc get konflux konflux -o yaml || true
    exit 1
fi

echo "Konflux installation is ready!"
oc get konflux konflux


