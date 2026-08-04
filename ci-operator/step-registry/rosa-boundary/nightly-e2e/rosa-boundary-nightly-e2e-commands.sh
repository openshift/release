#!/bin/bash

set -euo pipefail

echo "Starting rosa-boundary e2e tests..."

# Infrastructure details are available in:
# ${SHARED_DIR}/rosa-boundary-network-outputs.json
# ${SHARED_DIR}/rosa-boundary-regional-outputs.json

# If tests need infrastructure outputs, they can read them via jq:
# ENDPOINT=$(jq -r '.endpoint_url.value' "${SHARED_DIR}/rosa-boundary-regional-outputs.json")

# Run tests using Makefile target
echo "Running make test..."
make test

echo "E2E tests completed successfully"
