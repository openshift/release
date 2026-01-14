#!/bin/bash

set -euo pipefail

# Function to collect debug artifacts - runs on exit (success or failure)
function collectArtifacts {
  echo "=== Collecting debug artifacts ==="
  
  # Save pod descriptions
  oc describe pods -n "${CHA_NAMESPACE}" > "${ARTIFACT_DIR}/pod-describe.txt" 2>&1 || true
  
  # Save full pod logs
  oc logs "deployment/${CHA_DEPLOYMENT_NAME}" -n "${CHA_NAMESPACE}" --all-containers > "${ARTIFACT_DIR}/pod-logs.txt" 2>&1 || true
  
  # Save previous pod logs (if pod restarted)
  oc logs "deployment/${CHA_DEPLOYMENT_NAME}" -n "${CHA_NAMESPACE}" --all-containers --previous > "${ARTIFACT_DIR}/pod-logs-previous.txt" 2>&1 || true
  
  # Save events
  oc get events -n "${CHA_NAMESPACE}" --sort-by='.lastTimestamp' > "${ARTIFACT_DIR}/events.txt" 2>&1 || true
  
  # Save deployment status
  oc get deployment -n "${CHA_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/deployment.yaml" 2>&1 || true
  
  # Save all resources in namespace
  oc get all -n "${CHA_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/all-resources.yaml" 2>&1 || true
  
  echo "=== Artifacts collected in ${ARTIFACT_DIR} ==="
}

# Always collect artifacts on exit
trap collectArtifacts EXIT

echo "=== Cluster Health Analyzer Deployment ==="
echo "CHA_IMAGE: ${CHA_IMAGE}"
echo "CHA_MANIFESTS_PATH: ${CHA_MANIFESTS_PATH}"
echo "CHA_DEPLOYMENT_NAME: ${CHA_DEPLOYMENT_NAME}"
echo "CHA_NAMESPACE: ${CHA_NAMESPACE}"

# Export variables with names expected by the make targets / deploy scripts
export NAMESPACE="${CHA_NAMESPACE}"
export MANIFESTS_PATH="${CHA_MANIFESTS_PATH}"
export DEPLOYMENT_NAME="${CHA_DEPLOYMENT_NAME}"
# CHA_IMAGE is already named correctly

# Install yq if not available
if ! command -v yq &> /dev/null; then
  echo "=== Installing yq ==="
  curl -sL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /tmp/yq
  chmod +x /tmp/yq
  export PATH="/tmp:${PATH}"
fi

echo "=== Running make targets ==="
echo "=== Running undeploy-integration ==="
echo "--------------------------------"
make undeploy-integration
echo "=== Running deploy-integration ==="
echo "--------------------------------"
make deploy-integration
echo "=== Running test-integration ==="
echo "--------------------------------"
make test-integration

echo "=== Deployment successful ==="
