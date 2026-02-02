#!/bin/bash
set -o nounset
set -o pipefail

echo "=== AWS Neuron Deprovision Gate ==="

# Check if skip.txt exists - no cluster to deprovision
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "SKIP: No cluster was provisioned - nothing to deprovision"
  exit 0
fi

# Check provision status
if [ -f "${SHARED_DIR}/provision-status" ] && [ "$(cat ${SHARED_DIR}/provision-status)" == "skipped" ]; then
  echo "SKIP: Cluster was not provisioned - nothing to deprovision"
  exit 0
fi

echo "Cluster was provisioned - deprovisioning will be handled by the chain"
# The actual deprovisioning is handled by rosa-aws-sts-hcp-deprovision chain
