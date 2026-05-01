#!/bin/bash

set -euo pipefail

echo "[INFO] Deprovisioning spoke cluster"

# Check if spoke cluster was created
if [[ ! -f "${SHARED_DIR}/spoke-cluster-name" ]]; then
  echo "[INFO] No spoke cluster to clean up"
  exit 0
fi

SPOKE_CLUSTER_NAME="$(cat ${SHARED_DIR}/spoke-cluster-name)"
echo "[INFO] Spoke cluster name: ${SPOKE_CLUSTER_NAME}"

# Check if namespace exists
if ! oc get namespace "${SPOKE_CLUSTER_NAME}" &>/dev/null; then
  echo "[INFO] Spoke cluster namespace ${SPOKE_CLUSTER_NAME} not found, nothing to clean up"
  exit 0
fi

# Check if ClusterDeployment exists
if ! oc -n "${SPOKE_CLUSTER_NAME}" get clusterdeployment "${SPOKE_CLUSTER_NAME}" &>/dev/null; then
  echo "[INFO] ClusterDeployment ${SPOKE_CLUSTER_NAME} not found"
  echo "[INFO] Cleaning up namespace"
  oc delete namespace "${SPOKE_CLUSTER_NAME}" --ignore-not-found=true --wait=false || true
  exit 0
fi

echo "[INFO] Found ClusterDeployment ${SPOKE_CLUSTER_NAME}, initiating deprovision"

# Ensure infrastructure is destroyed (not preserved)
echo "[INFO] Patching ClusterDeployment to ensure infrastructure cleanup"
oc -n "${SPOKE_CLUSTER_NAME}" patch clusterdeployment "${SPOKE_CLUSTER_NAME}" \
  --type=merge -p '{"spec":{"preserveOnDelete":false}}' || true

# Delete ClusterDeployment (this triggers Hive to deprovision)
echo "[INFO] Deleting ClusterDeployment ${SPOKE_CLUSTER_NAME}"
oc -n "${SPOKE_CLUSTER_NAME}" delete clusterdeployment "${SPOKE_CLUSTER_NAME}" \
  --wait=false --ignore-not-found=true

# Wait for deprovision to complete
echo "[INFO] Waiting for spoke cluster deprovision to complete (timeout: 60m)"
timeout_seconds=3600  # 60 minutes
elapsed=0
poll_interval=15

while [[ $elapsed -lt $timeout_seconds ]]; do
  # Check if ClusterDeployment still exists
  if ! oc -n "${SPOKE_CLUSTER_NAME}" get clusterdeployment "${SPOKE_CLUSTER_NAME}" &>/dev/null; then
    echo "[SUCCESS] ClusterDeployment deleted, deprovision complete"
    break
  fi

  # Check deprovision status
  deprovision_status=$(oc -n "${SPOKE_CLUSTER_NAME}" get clusterdeployment "${SPOKE_CLUSTER_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="DeprovisionLaunchError")].status}' 2>/dev/null || echo "")

  if [[ "${deprovision_status}" == "True" ]]; then
    echo "[ERROR] Deprovision encountered an error"
    oc -n "${SPOKE_CLUSTER_NAME}" get clusterdeployment "${SPOKE_CLUSTER_NAME}" -o yaml
    # Continue waiting, don't fail immediately
  fi

  # Show progress
  if [[ $((elapsed % 60)) -eq 0 ]]; then
    echo "[INFO] Still waiting for deprovision... (${elapsed}s elapsed)"
    oc -n "${SPOKE_CLUSTER_NAME}" get clusterdeployment "${SPOKE_CLUSTER_NAME}" \
      -o jsonpath='{.status.conditions}' | jq '.' 2>/dev/null || true
  fi

  sleep $poll_interval
  elapsed=$((elapsed + poll_interval))
done

# Check final status
if oc -n "${SPOKE_CLUSTER_NAME}" get clusterdeployment "${SPOKE_CLUSTER_NAME}" &>/dev/null; then
  echo "[WARN] Spoke cluster deprovision did not complete within timeout"
  echo "[WARN] ClusterDeployment may require manual cleanup"
  oc -n "${SPOKE_CLUSTER_NAME}" get clusterdeployment "${SPOKE_CLUSTER_NAME}" -o yaml || true

  # Force delete the ClusterDeployment to allow cleanup to proceed
  echo "[WARN] Force deleting ClusterDeployment"
  oc -n "${SPOKE_CLUSTER_NAME}" delete clusterdeployment "${SPOKE_CLUSTER_NAME}" \
    --force --grace-period=0 --ignore-not-found=true || true
else
  echo "[SUCCESS] Spoke cluster deprovisioned successfully"
fi

# Clean up namespace
echo "[INFO] Cleaning up spoke cluster namespace"
oc delete namespace "${SPOKE_CLUSTER_NAME}" --ignore-not-found=true --wait=false || true

# Clean up ClusterImageSet
if [[ -f "${SHARED_DIR}/spoke-clusterimageset-name" ]]; then
  IMAGESET_NAME="$(cat ${SHARED_DIR}/spoke-clusterimageset-name)"
  echo "[INFO] Cleaning up ClusterImageSet ${IMAGESET_NAME}"
  oc delete clusterimageset "${IMAGESET_NAME}" --ignore-not-found=true || true
fi

echo "[INFO] Spoke cluster cleanup completed"
exit 0
