#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "=== AWS Neuron Kernel Version Check ==="

# Configuration
DTK_JSON_URL="https://raw.githubusercontent.com/awslabs/kmod-with-kmm-for-ai-chips-on-aws/main/driver-toolkit/driver-toolkit.json"
OCP_VERSION="${OPENSHIFT_VERSION:-4.20}"

# Fetch driver-toolkit.json
echo "Fetching driver-toolkit.json..."
if ! curl -sL "${DTK_JSON_URL}" -o /tmp/driver-toolkit.json; then
  echo "WARNING: Failed to fetch driver-toolkit.json - proceeding with full test"
  exit 0
fi

# Get the current commit SHA of the DTK JSON file
echo "Checking driver-toolkit.json commit history..."
CURRENT_COMMIT=$(curl -sL "https://api.github.com/repos/awslabs/kmod-with-kmm-for-ai-chips-on-aws/commits?path=driver-toolkit/driver-toolkit.json&per_page=1" 2>/dev/null | jq -r '.[0].sha // empty' || echo "")

if [ -z "${CURRENT_COMMIT}" ]; then
  echo "WARNING: Could not fetch commit info - proceeding with full test"
  exit 0
fi

echo "Latest DTK JSON commit: ${CURRENT_COMMIT:0:12}"

# Compare with the known/expected commit
LAST_KNOWN_COMMIT="${LAST_KNOWN_DTK_COMMIT:-}"

if [ -z "${LAST_KNOWN_COMMIT}" ]; then
  echo "No previous commit recorded (LAST_KNOWN_DTK_COMMIT not set)"
  echo "This is the first run - proceeding with full test"
  echo "${CURRENT_COMMIT}" > "${SHARED_DIR}/current-dtk-commit"
  exit 0
fi

if [ "${CURRENT_COMMIT}" == "${LAST_KNOWN_COMMIT}" ]; then
  echo "============================================================"
  echo "OPTIMIZATION: DTK JSON unchanged since last check"
  echo "Commit: ${CURRENT_COMMIT:0:12}"
  echo ""
  echo "Creating skip.txt to signal workflow skip"
  echo "============================================================"
  
  # Create the skip file - this signals all subsequent steps to exit early
  touch "${SHARED_DIR}/skip.txt"
  echo "kernel_unchanged" > "${SHARED_DIR}/skip.txt"
  
  # Store the commit for reference
  echo "${CURRENT_COMMIT}" > "${SHARED_DIR}/current-dtk-commit"
  
  exit 0
else
  echo "DTK JSON has been updated!"
  echo "Previous commit: ${LAST_KNOWN_COMMIT:0:12}"
  echo "Current commit:  ${CURRENT_COMMIT:0:12}"
  echo ""
  echo "Proceeding with full cluster provisioning and tests"
  
  # Store the new commit for reference
  echo "${CURRENT_COMMIT}" > "${SHARED_DIR}/current-dtk-commit"
fi
