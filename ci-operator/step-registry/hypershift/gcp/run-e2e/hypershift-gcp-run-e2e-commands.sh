#!/usr/bin/env bash

set -euo pipefail

# This step runs e2e tests against a HyperShift Control Plane cluster on GKE
# Currently this is a placeholder that runs basic validation
# Full e2e test suite will be integrated once infrastructure is validated

echo "Starting HyperShift GCP e2e tests..."

# The kubeconfig from gke-provision uses a static access token,
# so no gcloud/auth-plugin installation is needed here.

# Load kubeconfig for the Control Plane cluster
if [[ ! -f "${SHARED_DIR}/kubeconfig" ]]; then
    echo "ERROR: Control Plane cluster kubeconfig not found"
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
