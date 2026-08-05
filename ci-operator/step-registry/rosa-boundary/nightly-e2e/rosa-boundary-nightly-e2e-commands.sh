#!/bin/bash

set -euo pipefail

echo "Starting rosa-boundary e2e tests..."

# Infrastructure details are available in:
# ${SHARED_DIR}/rosa-boundary-network-outputs.json
# ${SHARED_DIR}/rosa-boundary-regional-outputs.json

# Verify infrastructure was provisioned
echo "Verifying infrastructure outputs..."
if [[ ! -f "${SHARED_DIR}/rosa-boundary-network-outputs.json" ]]; then
  echo "ERROR: Network outputs not found"
  exit 1
fi

if [[ ! -f "${SHARED_DIR}/rosa-boundary-regional-outputs.json" ]]; then
  echo "ERROR: Regional outputs not found"
  exit 1
fi

# Display provisioned infrastructure
echo "Network outputs:"
jq '.' "${SHARED_DIR}/rosa-boundary-network-outputs.json"

echo "Regional outputs:"
jq '.' "${SHARED_DIR}/rosa-boundary-regional-outputs.json"

# Run Go CLI unit tests (validates CLI functionality)
echo "Running CLI unit tests..."
make test-cli

# Run Lambda unit tests (validates Lambda functions)
echo "Running Lambda unit tests..."
make test-lambda

echo "E2E tests completed successfully"
