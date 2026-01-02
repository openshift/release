#!/bin/bash

set -euxo pipefail

# Read cluster name and namespace from shared directory
if [ ! -f "${SHARED_DIR}/hive-cluster-name" ]; then
  echo "WARNING: Cluster name file not found, skipping cleanup"
  exit 0
fi

HIVE_CLUSTER_NAME="$(cat "${SHARED_DIR}/hive-cluster-name")"
NAMESPACE="$(cat "${SHARED_DIR}/hive-cluster-namespace")"

echo "Cleaning up Hive ClusterDeployment: ${HIVE_CLUSTER_NAME} in namespace ${NAMESPACE}"

# Check if the ClusterDeployment exists
if ! oc get clusterdeployment "${HIVE_CLUSTER_NAME}" -n "${NAMESPACE}" &>/dev/null; then
  echo "ClusterDeployment ${HIVE_CLUSTER_NAME} not found, nothing to clean up"
  exit 0
fi

# Get current status before deletion
echo "Current ClusterDeployment status:"
oc get clusterdeployment "${HIVE_CLUSTER_NAME}" -n "${NAMESPACE}" -o yaml || true

# Delete the ClusterDeployment
echo "Deleting ClusterDeployment ${HIVE_CLUSTER_NAME}..."
oc delete clusterdeployment "${HIVE_CLUSTER_NAME}" -n "${NAMESPACE}" --wait=false || true

# Wait for the ClusterDeployment to be fully deprovisioned
echo "Waiting for ClusterDeployment to be deleted (timeout: 45m)..."
for i in {1..90}; do
  if ! oc get clusterdeployment "${HIVE_CLUSTER_NAME}" -n "${NAMESPACE}" &>/dev/null; then
    echo "ClusterDeployment ${HIVE_CLUSTER_NAME} has been deleted successfully"
    break
  fi

  if [ $i -eq 90 ]; then
    echo "WARNING: ClusterDeployment deletion timed out after 45 minutes"
    echo "Current status:"
    oc get clusterdeployment "${HIVE_CLUSTER_NAME}" -n "${NAMESPACE}" -o yaml || true
    # Continue anyway as this is best_effort
    break
  fi

  echo "Waiting for deprovision... ($i/90)"
  sleep 30
done

# Clean up namespace
echo "Deleting namespace ${NAMESPACE}..."
oc delete namespace "${NAMESPACE}" --wait=false || true

echo "Cleanup complete"
