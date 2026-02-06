#!/usr/bin/env bash

set -euo pipefail

# This step runs e2e tests against a HyperShift management cluster on GKE
# Currently this is a placeholder that runs basic validation
# Full e2e test suite will be integrated once infrastructure is validated

echo "Starting HyperShift GCP e2e tests..."

# Install GKE auth plugin using the shared script from gke-provision step
# Each step runs in a separate pod, so we need to install the plugin in each step
# The upi-installer image has gcloud pre-installed, we just need the plugin
# Copy script locally since SHARED_DIR (backed by k8s secret) doesn't preserve execute permissions
INSTALL_SCRIPT=$(mktemp)
cp "${SHARED_DIR}/install-gke-auth-plugin.sh" "${INSTALL_SCRIPT}"
chmod +x "${INSTALL_SCRIPT}"
"${INSTALL_SCRIPT}"
rm -f "${INSTALL_SCRIPT}"
export PATH="${PATH}:${HOME}/bin"
export USE_GKE_GCLOUD_AUTH_PLUGIN=True

# Authenticate gcloud with the service account from the cluster profile
echo "Authenticating gcloud with service account..."
gcloud auth activate-service-account --key-file="${CLUSTER_PROFILE_DIR}/credentials.json"

# Load kubeconfig for the management cluster
if [[ ! -f "${SHARED_DIR}/kubeconfig" ]]; then
    echo "ERROR: Management cluster kubeconfig not found"
    exit 1
fi


export KUBECONFIG="${SHARED_DIR}/kubeconfig"

set -x

# Verify HyperShift operator is running
echo "=== Verifying HyperShift Operator ==="
oc wait --for=condition=Available deployment/operator -n hypershift --timeout=300s

# Check HyperShift CRDs are installed
echo "=== Checking HyperShift CRDs ==="
oc get crd hostedclusters.hypershift.openshift.io
oc get crd nodepools.hypershift.openshift.io

# Verify no HyperShift pods are in error state
echo "=== Checking HyperShift Pod Health ==="
UNHEALTHY_PODS=$(oc get pods -n hypershift --no-headers | grep -v -E "Running|Completed" | wc -l || true)
if [[ "${UNHEALTHY_PODS}" -gt 0 ]]; then
    echo "WARNING: Found ${UNHEALTHY_PODS} unhealthy pods in hypershift namespace"
    oc get pods -n hypershift
fi

# Basic connectivity test
echo "=== Testing Cluster Connectivity ==="
oc cluster-info
oc get nodes -o wide

# TODO: Add full e2e test execution once infrastructure is validated
# This will include:
# - Creating a HostedCluster on GCP
# - Validating NodePool scaling
# - Running conformance tests
# - Cleanup

echo "=== Basic Validation Complete ==="
echo "HyperShift operator is running and CRDs are installed"
echo "Full e2e tests will be added in future iterations"