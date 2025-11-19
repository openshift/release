#!/bin/bash

set -o nounset
set -o pipefail

echo "Deprovisioning Hive ClusterDeployment for IBM Cloud"

# Read spoke cluster details from SHARED_DIR (may not exist if create failed)
SPOKE_CLUSTER_NAME="$(cat "${SHARED_DIR}/hive-spoke-cluster-name" 2>/dev/null || echo "")"
SPOKE_NAMESPACE="$(cat "${SHARED_DIR}/hive-spoke-namespace" 2>/dev/null || echo "")"

if [ -z "${SPOKE_CLUSTER_NAME}" ] || [ -z "${SPOKE_NAMESPACE}" ]; then
  echo "No spoke cluster to deprovision (create step may have failed)"
  exit 0
fi

echo "Spoke cluster name: ${SPOKE_CLUSTER_NAME}"
echo "Spoke namespace: ${SPOKE_NAMESPACE}"

# Check if namespace still exists
if ! oc get namespace "${SPOKE_NAMESPACE}" &>/dev/null; then
  echo "Namespace ${SPOKE_NAMESPACE} does not exist, nothing to clean up"
  exit 0
fi

# Gather ClusterDeployment final state before deletion
echo "Gathering ClusterDeployment state before deletion..."
if oc get clusterdeployment -n "${SPOKE_NAMESPACE}" "${SPOKE_CLUSTER_NAME}" &>/dev/null; then
  oc get clusterdeployment -n "${SPOKE_NAMESPACE}" "${SPOKE_CLUSTER_NAME}" -o yaml \
    > "${ARTIFACT_DIR}/clusterdeployment-final.yaml" || true

  # Delete ClusterDeployment (Hive will deprovision the cluster)
  echo "Deleting ClusterDeployment ${SPOKE_CLUSTER_NAME}..."
  oc delete clusterdeployment -n "${SPOKE_NAMESPACE}" "${SPOKE_CLUSTER_NAME}" --wait=false || true
else
  echo "ClusterDeployment ${SPOKE_CLUSTER_NAME} does not exist"
fi

# Delete namespace (will wait for finalizers)
echo "Deleting namespace ${SPOKE_NAMESPACE}..."
oc delete namespace "${SPOKE_NAMESPACE}" --wait=false || true

# Wait for namespace deletion with timeout
echo "Waiting for namespace deletion (max 30m)..."
set +e
timeout 30m bash -c "
  while oc get namespace ${SPOKE_NAMESPACE} 2>/dev/null; do
    echo 'Waiting for namespace deletion...'
    sleep 30
  done
"
result=$?
set -e

if [ ${result} -eq 124 ]; then
  echo "Warning: Namespace deletion timed out after 30 minutes"
  echo "Namespace may still be cleaning up in the background"
  oc get namespace "${SPOKE_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/namespace-stuck.yaml" || true
  oc get clusterdeployment -n "${SPOKE_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/clusterdeployment-stuck.yaml" || true
elif [ ${result} -eq 0 ]; then
  echo "Namespace ${SPOKE_NAMESPACE} deleted successfully"
else
  echo "Warning: Namespace deletion monitoring failed with exit code ${result}"
fi

echo "Deprovision complete"
