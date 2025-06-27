#!/bin/bash
set -x
set -o errexit
set -o nounset
set -o pipefail

echo "Starting egressIP tests for HyperShift KubeVirt cluster"

# Wait for the cluster to be ready
echo "Waiting for cluster to be ready..."
oc wait clusterversion/version --for='condition=Available=True' --timeout=30m

# Wait for all operators to be ready
echo "Waiting for all operators to be ready..."
oc wait --all --for=condition=Available=True --timeout=10m clusteroperators.config.openshift.io

# Verify network type is OVNKubernetes (required for egressIP)
echo "Verifying network type..."
NETWORK_TYPE=$(oc get network.operator cluster -o jsonpath='{.spec.defaultNetwork.type}')
if [[ "$NETWORK_TYPE" != "OVNKubernetes" ]]; then
    echo "Error: Network type is $NETWORK_TYPE, but egressIP requires OVNKubernetes"
    exit 1
fi
echo "Network type is OVNKubernetes - proceeding with egressIP tests"

# Check if egressIP feature is available
echo "Checking egressIP feature availability..."
if ! oc get crd egressips.k8s.ovn.org; then
    echo "Error: egressIP CRD not found. egressIP feature may not be available."
    exit 1
fi

# Run the egressIP tests
echo "Running egressIP conformance tests..."
TEST_ARGS="${TEST_ARGS:-'--run [sig-network][Feature:EgressIP]'}"
TEST_SUITE="${TEST_SUITE:-'openshift/conformance/serial'}"

# Execute the test suite
openshift-tests run ${TEST_SUITE} ${TEST_ARGS} \
    --kubeconfig "${KUBECONFIG}" \
    --provider=none \
    -v=2 \
    --timeout=30m

echo "egressIP tests completed successfully" 