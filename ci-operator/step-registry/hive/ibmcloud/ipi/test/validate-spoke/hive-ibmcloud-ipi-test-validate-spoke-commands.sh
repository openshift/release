#!/bin/bash

set -euo pipefail

echo "[INFO] Validating spoke cluster installation"

# Read spoke cluster name
SPOKE_CLUSTER_NAME="$(cat ${SHARED_DIR}/spoke-cluster-name)"
TIMEOUT="${SPOKE_INSTALL_TIMEOUT:-90m}"

echo "[INFO] Spoke cluster name: ${SPOKE_CLUSTER_NAME}"
echo "[INFO] Installation timeout: ${TIMEOUT}"

# Monitor ClusterDeployment status
echo "[INFO] Waiting for spoke cluster ${SPOKE_CLUSTER_NAME} to be provisioned (timeout: ${TIMEOUT})"

# Wait for ClusterDeployment to be provisioned
if ! oc -n "${SPOKE_CLUSTER_NAME}" wait "clusterdeployment/${SPOKE_CLUSTER_NAME}" \
  --for condition=Provisioned \
  --timeout "${TIMEOUT}"; then
  echo "[ERROR] ClusterDeployment did not reach Provisioned condition within timeout"
  echo "[ERROR] ClusterDeployment status:"
  oc -n "${SPOKE_CLUSTER_NAME}" get clusterdeployment "${SPOKE_CLUSTER_NAME}" -o yaml
  echo "[ERROR] Checking provision job logs:"
  oc -n "${SPOKE_CLUSTER_NAME}" get jobs -l "hive.openshift.io/cluster-deployment-name=${SPOKE_CLUSTER_NAME}"
  # Try to get install job logs
  INSTALL_JOB=$(oc -n "${SPOKE_CLUSTER_NAME}" get jobs -l "hive.openshift.io/cluster-deployment-name=${SPOKE_CLUSTER_NAME},hive.openshift.io/job-type=provision" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "${INSTALL_JOB}" ]]; then
    echo "[ERROR] Install job logs:"
    oc -n "${SPOKE_CLUSTER_NAME}" logs "job/${INSTALL_JOB}" --tail=100 || true
  fi
  exit 1
fi

# Verify provisioning status
cd_status=$(oc -n "${SPOKE_CLUSTER_NAME}" get clusterdeployment "${SPOKE_CLUSTER_NAME}" \
  -o jsonpath='{.status.conditions[?(@.type=="Provisioned")].status}')

if [[ "${cd_status}" != "True" ]]; then
  echo "[ERROR] Spoke cluster provisioning failed - Provisioned condition is not True"
  echo "[ERROR] ClusterDeployment conditions:"
  oc -n "${SPOKE_CLUSTER_NAME}" get clusterdeployment "${SPOKE_CLUSTER_NAME}" \
    -o jsonpath='{.status.conditions}' | jq '.'
  exit 1
fi

echo "[SUCCESS] Spoke cluster provisioned successfully"

# Extract spoke cluster kubeconfig
echo "[INFO] Extracting spoke cluster kubeconfig"
admin_kubeconfig_secret=$(oc -n "${SPOKE_CLUSTER_NAME}" get clusterdeployment "${SPOKE_CLUSTER_NAME}" \
  -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}')

if [[ -z "${admin_kubeconfig_secret}" ]]; then
  echo "[ERROR] Could not find admin kubeconfig secret reference"
  exit 1
fi

echo "[INFO] Admin kubeconfig secret: ${admin_kubeconfig_secret}"

oc -n "${SPOKE_CLUSTER_NAME}" get secret "${admin_kubeconfig_secret}" \
  -o jsonpath='{.data.kubeconfig}' | base64 -d > "${SHARED_DIR}/spoke-kubeconfig"

if [[ ! -s "${SHARED_DIR}/spoke-kubeconfig" ]]; then
  echo "[ERROR] Spoke kubeconfig is empty"
  exit 1
fi

echo "[SUCCESS] Spoke cluster kubeconfig extracted"

# Validate spoke cluster is accessible
echo "[INFO] Validating spoke cluster accessibility"
export KUBECONFIG="${SHARED_DIR}/spoke-kubeconfig"

# Test cluster connectivity
if ! oc whoami &>/dev/null; then
  echo "[ERROR] Cannot authenticate to spoke cluster"
  exit 1
fi

echo "[SUCCESS] Successfully authenticated to spoke cluster"

# Get cluster nodes
echo "[INFO] Spoke cluster nodes:"
if ! oc get nodes; then
  echo "[ERROR] Failed to get nodes from spoke cluster"
  exit 1
fi

# Verify nodes are ready
NOT_READY_NODES=$(oc get nodes --no-headers | grep -v " Ready" | wc -l)
if [[ ${NOT_READY_NODES} -gt 0 ]]; then
  echo "[WARN] Some nodes are not Ready"
  oc get nodes
fi

# Get cluster version
echo "[INFO] Spoke cluster version:"
if ! oc get clusterversion; then
  echo "[ERROR] Failed to get clusterversion from spoke cluster"
  exit 1
fi

# Get cluster operators status
echo "[INFO] Spoke cluster operators:"
oc get clusteroperators

# Check for degraded cluster operators
DEGRADED_OPS=$(oc get clusteroperators --no-headers | grep -E "False.*True|False.*False.*True" | wc -l || true)
if [[ ${DEGRADED_OPS} -gt 0 ]]; then
  echo "[WARN] Some cluster operators are degraded:"
  oc get clusteroperators | grep -E "False.*True|False.*False.*True" || true
fi

# Save cluster info to artifacts
mkdir -p "${ARTIFACT_DIR}/spoke-cluster" || true
oc get nodes -o yaml > "${ARTIFACT_DIR}/spoke-cluster/nodes.yaml" || true
oc get clusterversion -o yaml > "${ARTIFACT_DIR}/spoke-cluster/clusterversion.yaml" || true
oc get clusteroperators -o yaml > "${ARTIFACT_DIR}/spoke-cluster/clusteroperators.yaml" || true

# Get spoke cluster details
SPOKE_API_URL=$(oc whoami --show-server)
SPOKE_CONSOLE_URL=$(oc get routes -n openshift-console console -o jsonpath='{.spec.host}' 2>/dev/null || echo "N/A")

echo ""
echo "=========================================="
echo "[SUCCESS] Spoke Cluster Validation Complete"
echo "=========================================="
echo "Cluster Name: ${SPOKE_CLUSTER_NAME}"
echo "API URL: ${SPOKE_API_URL}"
echo "Console URL: https://${SPOKE_CONSOLE_URL}"
echo "Kubeconfig: ${SHARED_DIR}/spoke-kubeconfig"
echo "=========================================="
echo ""

exit 0
