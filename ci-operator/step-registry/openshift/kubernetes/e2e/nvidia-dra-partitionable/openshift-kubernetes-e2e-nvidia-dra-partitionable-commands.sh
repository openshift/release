#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
export ARTIFACTS="${ARTIFACT_DIR}"

readonly GPU_LABEL="nvidia.com/gpu.present=true"
readonly DRA_DEVICECLASS="nvidia.com/gpu"

echo "Test Focus: ${DRA_TEST_FOCUS}"

# Verify GPU nodes
readonly GPU_NODES=$(oc get nodes -l "${GPU_LABEL}" -o name 2>/dev/null | wc -l)
if [ "${GPU_NODES}" -eq 0 ]; then
  echo "ERROR: No GPU nodes found with label ${GPU_LABEL}"
  oc get nodes --show-labels
  exit 1
fi
echo "Found ${GPU_NODES} GPU node(s)"
oc get nodes -l "${GPU_LABEL}" -o wide

# Verify NVIDIA DRA driver
if ! oc get deviceclass "${DRA_DEVICECLASS}" &>/dev/null; then
  echo "ERROR: DeviceClass ${DRA_DEVICECLASS} not found"
  exit 1
fi
echo "DeviceClass ${DRA_DEVICECLASS} exists"

# Check ResourceSlices
RESOURCE_SLICES=$(oc get resourceslice -o name 2>/dev/null | wc -l)
echo "ResourceSlices: ${RESOURCE_SLICES}"
if [ "${RESOURCE_SLICES}" -eq 0 ]; then
  echo "WARNING: No ResourceSlices found"
fi

# Verify DRAPartitionableDevices feature gate if needed
if [[ "${DRA_TEST_FOCUS}" == *"DRAPartitionableDevices"* ]]; then
  ENABLED_GATES=$(oc get featuregate cluster -o jsonpath='{.spec.customNoUpgrade.enabled}' 2>/dev/null || echo "[]")
  if [[ "${ENABLED_GATES}" != *"DRAPartitionableDevices"* ]]; then
    echo "ERROR: DRAPartitionableDevices feature gate not enabled"
    exit 1
  fi
  echo "DRAPartitionableDevices feature gate enabled"
fi

# Configure test arguments
PLATFORM="${CLUSTER_TYPE:-gcp}"
NETWORK_SKIPS="\[Skipped:Network/OVNKubernetes\]|\[Feature:Networking-IPv6\]|\[Feature:IPv6DualStack.*\]|\[Feature:SCTPConnectivity\]"
COMMON_SKIPS="\[Slow\]|\[Disruptive\]|\[Flaky\]|\[Disabled:.+\]|\[Skipped:${PLATFORM}\]|\[DedicatedJob\]|${NETWORK_SKIPS}"
export KUBE_E2E_TEST_ARGS="-focus=${DRA_TEST_FOCUS} -skip=${COMMON_SKIPS}"

echo "Running Kubernetes E2E tests: ${KUBE_E2E_TEST_ARGS}"
test-kubernetes-e2e.sh
