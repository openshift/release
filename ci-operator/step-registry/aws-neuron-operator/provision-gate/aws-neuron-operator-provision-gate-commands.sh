#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "=== AWS Neuron Provision Gate ==="

# Check if skip.txt exists (created by kernel-check step)
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  SKIP_REASON=$(cat "${SHARED_DIR}/skip.txt")
  echo "============================================================"
  echo "SKIP DETECTED: ${SKIP_REASON}"
  echo ""
  echo "Skipping cluster provisioning - kernel has not changed"
  echo "============================================================"
  
  # Create placeholder files that subsequent steps might expect
  echo "no-cluster-created" > "${SHARED_DIR}/cluster-id"
  echo "skipped" > "${SHARED_DIR}/provision-status"
  
  exit 0
fi

echo "No skip.txt found - proceeding with cluster provisioning"
echo "running" > "${SHARED_DIR}/provision-status"

# The actual provisioning is handled by the chain that follows this step
