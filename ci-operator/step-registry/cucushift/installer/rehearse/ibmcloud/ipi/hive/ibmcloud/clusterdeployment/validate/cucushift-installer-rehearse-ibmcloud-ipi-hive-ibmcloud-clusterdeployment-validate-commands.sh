#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Validating Hive ClusterDeployment for IBM Cloud"

# Read spoke cluster details from SHARED_DIR
SPOKE_CLUSTER_NAME="$(cat "${SHARED_DIR}/hive-spoke-cluster-name")"
SPOKE_NAMESPACE="$(cat "${SHARED_DIR}/hive-spoke-namespace")"
TIMEOUT="${SPOKE_CLUSTER_TIMEOUT:-90m}"

echo "Spoke cluster name: ${SPOKE_CLUSTER_NAME}"
echo "Spoke namespace: ${SPOKE_NAMESPACE}"
echo "Timeout: ${TIMEOUT}"

# Wait for ClusterDeployment to be provisioned
echo "Waiting for ClusterDeployment ${SPOKE_CLUSTER_NAME} to be provisioned (timeout: ${TIMEOUT})..."
set +e
oc wait --timeout="${TIMEOUT}" \
  --for=condition=Provisioned \
  --namespace="${SPOKE_NAMESPACE}" \
  clusterdeployment/"${SPOKE_CLUSTER_NAME}"
wait_result=$?
set -e

# Check ClusterDeployment status
echo "Checking ClusterDeployment status..."
oc get clusterdeployment -n "${SPOKE_NAMESPACE}" "${SPOKE_CLUSTER_NAME}" -o yaml | tee "${ARTIFACT_DIR}/clusterdeployment-status.yaml"

# Check if provisioning failed
PROVISION_FAILED=$(oc get clusterdeployment -n "${SPOKE_NAMESPACE}" "${SPOKE_CLUSTER_NAME}" \
  -o jsonpath='{.status.conditions[?(@.type=="ProvisionFailed")].status}' || echo "")

if [ "${PROVISION_FAILED}" == "True" ]; then
  echo "ERROR: ClusterDeployment provisioning failed"
  FAILURE_MESSAGE=$(oc get clusterdeployment -n "${SPOKE_NAMESPACE}" "${SPOKE_CLUSTER_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="ProvisionFailed")].message}' || echo "")
  echo "Failure message: ${FAILURE_MESSAGE}"

  # Try to get install logs
  echo "Attempting to gather install logs..."
  oc get clusterdeployment -n "${SPOKE_NAMESPACE}" "${SPOKE_CLUSTER_NAME}" -o yaml > "${ARTIFACT_DIR}/failed-clusterdeployment.yaml"

  exit 1
fi

if [ ${wait_result} -ne 0 ]; then
  echo "ERROR: Timeout waiting for ClusterDeployment to be provisioned"
  exit 1
fi

echo "ClusterDeployment provisioned successfully"

# Extract kubeconfig from admin secret
echo "Extracting spoke cluster kubeconfig..."
KUBECONFIG_SECRET=$(oc get clusterdeployment -n "${SPOKE_NAMESPACE}" "${SPOKE_CLUSTER_NAME}" \
  -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}' || echo "")

if [ -z "${KUBECONFIG_SECRET}" ]; then
  echo "ERROR: Could not find admin kubeconfig secret reference"
  oc get clusterdeployment -n "${SPOKE_NAMESPACE}" "${SPOKE_CLUSTER_NAME}" -o yaml
  exit 1
fi

echo "Kubeconfig secret: ${KUBECONFIG_SECRET}"

oc extract secret/"${KUBECONFIG_SECRET}" \
  -n "${SPOKE_NAMESPACE}" \
  --to="${SHARED_DIR}" \
  --keys=kubeconfig \
  --confirm

mv "${SHARED_DIR}/kubeconfig" "${SHARED_DIR}/hive-spoke-kubeconfig"

# Validate spoke cluster accessibility
echo "Validating spoke cluster accessibility..."
export KUBECONFIG="${SHARED_DIR}/hive-spoke-kubeconfig"

echo "Getting cluster nodes..."
oc get nodes -o wide | tee "${ARTIFACT_DIR}/spoke-nodes.txt"

echo "Getting cluster version..."
oc get clusterversion -o yaml | tee "${ARTIFACT_DIR}/spoke-clusterversion.yaml"

# Wait for cluster operators to be available
echo "Waiting for cluster operators to be available (timeout: 30m)..."
timeout 30m bash -c '
  while true; do
    # Check if all cluster operators are Available
    NOT_AVAILABLE=$(oc get clusteroperators --no-headers | awk "{if (\$3 != \"True\" || \$4 == \"True\" || \$5 == \"True\") print \$1}" | wc -l | tr -d " ")

    if [ "${NOT_AVAILABLE}" == "0" ]; then
      echo "All cluster operators are available"
      break
    fi

    echo "Waiting for ${NOT_AVAILABLE} cluster operator(s) to become available..."
    oc get clusteroperators
    sleep 30
  done
'

echo "Cluster operators status:"
oc get clusteroperators | tee "${ARTIFACT_DIR}/spoke-clusteroperators.txt"

echo "Spoke cluster validation successful"
echo "Cluster: ${SPOKE_CLUSTER_NAME}"
echo "Namespace: ${SPOKE_NAMESPACE}"
