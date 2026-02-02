#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "Starting Neuron operator E2E tests..."

# Set up kubeconfig
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Verify cluster access
oc whoami
oc get nodes

# Verify Neuron nodes are present
echo "Checking for Neuron-capable nodes..."
INF2_NODES=$(oc get nodes -l node.kubernetes.io/instance-type=inf2.xlarge --no-headers | wc -l)
TRN1_NODES=$(oc get nodes -l node.kubernetes.io/instance-type=trn1.2xlarge --no-headers | wc -l)

echo "Found ${INF2_NODES} Inferentia2 nodes (inf2.xlarge)"
echo "Found ${TRN1_NODES} Trainium1 nodes (trn1.2xlarge)"

if [ "${INF2_NODES}" -lt 2 ]; then
  echo "ERROR: Expected at least 2 Inferentia2 nodes, found ${INF2_NODES}"
  exit 1
fi

if [ "${TRN1_NODES}" -lt 2 ]; then
  echo "ERROR: Expected at least 2 Trainium1 nodes, found ${TRN1_NODES}"
  exit 1
fi

# Run tests from eco-gotests
cd /home/testuser/eco-gotests

# Set test configuration
export ECO_DUMP_FAILED_TESTS=true
export ECO_REPORTS_DUMP_DIR="${ARTIFACT_DIR}/neuron-test-reports"
export ECO_VERBOSE_LEVEL=100

# Run all Neuron test suites
echo "Running Neuron test suites..."
make run-tests

echo "Neuron tests completed successfully"
