#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

VIRT_KUBECONFIG=/var/run/vault/vsphere-ibmcloud-config/vsphere-virt-kubeconfig
CLUSTER_KUBECONFIG=${SHARED_DIR}/kubeconfig
VM_NETWORK_PATCH=/var/run/vault/vsphere-ibmcloud-config/vm-network-patch.json
INFRA_PATCH=$(cat /var/run/vault/vsphere-ibmcloud-config/vsphere-virt-infra-patch)

VM_NAME="$(oc get infrastructure cluster -o json --kubeconfig=${CLUSTER_KUBECONFIG} | jq -r '.status.infrastructureName')-bm"
VM_NAMESPACE="${NAMESPACE}"

function approve_csrs() {
  CSR_COUNT=0
  echo "$(date -u --rfc-3339=seconds) - Approving the CSR requests for nodes..."
  # The cluster won't be ready to approve CSR(s) yet anyway
  sleep 90

  while true; do
    CSRS=$(oc get --kubeconfig=${CLUSTER_KUBECONFIG} csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name')
    if [[ $CSRS != "" ]]; then
      oc adm certificate approve $CSRS --kubeconfig=${CLUSTER_KUBECONFIG} || true
      CSR_COUNT=$(( CSR_COUNT + 1 ))
    fi
    if [[ $CSR_COUNT == $((2*${BM_COUNT})) ]]; then
        return 0
    fi
    sleep 15
  done
}

# Add 'node.openshift.io/platform-type=vsphere' label to any node that is missing it.
function label_vsphere_nodes() {
  echo "$(date -u --rfc-3339=seconds) - Adding labels to vsphere nodes for builds that do not have upstream ccm changes..."
  NODES=$(oc get nodes -o name --kubeconfig="${CLUSTER_KUBECONFIG}")
  for node in ${NODES}; do
    echo "$(date -u --rfc-3339=seconds) - Checking ${node}"
    LABEL_FOUND=$(oc get ${node} -o json | jq -r '.metadata.labels | has("node.openshift.io/platform-type")')
    if [ "${LABEL_FOUND}" == "false" ]; then
      echo "$(date -u --rfc-3339=seconds) - Adding 'node.openshift.io/platform-type=vsphere' label"
      oc label "${node}" "node.openshift.io/platform-type"=vsphere --kubeconfig="${CLUSTER_KUBECONFIG}"
    fi
  done
}

# Enable storage operator / capability.  If operator is already enabled, this function will log no changes made and operator is ready.
function enable_storage_operator() {
  echo "$(date -u --rfc-3339=seconds) - Enabling storage capability (operator)..."
  oc patch clusterversion/version --type merge -p '{"spec":{"capabilities":{"additionalEnabledCapabilities":["Storage"]}}}' --kubeconfig="${CLUSTER_KUBECONFIG}"

  # Wait for operator to be ready before progressing
  echo "$(date -u --rfc-3339=seconds) - Waiting for operator to be ready"
  while true; do
    OPERATOR_STATUS="$(oc get co storage --kubeconfig=${CLUSTER_KUBECONFIG} -o json --ignore-not-found)"
    # When first activating the operator, `oc get co` will not return storage operator.  When it does start installing it, it may also have no status set.
    if [[ ${OPERATOR_STATUS} != "" && "$(echo ${OPERATOR_STATUS} | jq -r '.status.conditions != null')" == "true" ]]; then
      IS_READY=$(echo ${OPERATOR_STATUS} | jq -r '(.status.conditions[] | select(.type == "Available") | .status == "True") and (.status.conditions[] | select(.type == "Degraded") | .status == "False") and (.status.conditions[] | select(.type == "Progressing") | .status == "False")')
      if [ "${IS_READY}" == "true" ]; then
        echo "$(date -u --rfc-3339=seconds) - Storage is ready"
        break
      fi
    fi
    sleep 5
  done
}

# Wait for the VM node to become ready
function wait_for_node_ready() {
  NODES=""
  for (( i=0; i<${BM_COUNT}; i++ )); do
    NODES="${NODES} ${VM_NAME}-${i}"
  done
  echo "$(date -u --rfc-3339=seconds) - Waiting for nodes ${NODES} to become Ready"
  oc wait --for=condition=Ready=True node ${NODES} --timeout=10m
  if [[ $? -ne 0 ]]; then
    echo "$(date -u --rfc-3339=seconds) - Nodes did not become ready"
    exit 1
  fi
}

# Wait for all cluster operators to become ready
function wait_for_co_ready() {
  echo "$(date -u --rfc-3339=seconds) - Waiting for cluster operators to become Ready / stable"
  oc adm wait-for-stable-cluster --minimum-stable-period=10s --timeout=10m
  if [[ $? -ne 0 ]]; then
    echo "$(date -u --rfc-3339=seconds) - All operators did not finish becoming Ready / stable"
    exit 1
  fi
}


# We are going to apply the 'node.openshift.io/platform-type=vsphere' label to all existing nodes as a workaround while waiting for upstream CCM changes
# When upstream changes are merged downstream, the function will output that no nodes were updated.
label_vsphere_nodes

# Enable storage operator now that the labels are in place
if [ "${ENABLE_HYBRID_STORAGE}" == "true" ]; then
  enable_storage_operator
fi

# Patch test cluster to have CIDR for non-vSphere node
oc patch infrastructure cluster --type json -p "${INFRA_PATCH}" --kubeconfig=${CLUSTER_KUBECONFIG}

# Generate YAML for creation VM
echo "$(date -u --rfc-3339=seconds) - Generating ignition data"
installer_bin=$(which openshift-install)
VIRT_IMAGE=$("${installer_bin}" coreos print-stream-json | jq -r '.architectures.x86_64.images.kubevirt.image')
echo ${VIRT_IMAGE}

IGNITION_DATA=$(oc get secret worker-user-data -n openshift-machine-api -o json --kubeconfig=${CLUSTER_KUBECONFIG} | jq -r '.data.userData')

echo "$(date -u --rfc-3339=seconds) - Generating virtual machine yaml"
for (( i=0; i<${BM_COUNT}; i++ )); do
  echo "$(date -u --rfc-3339=seconds) - Generating ${VM_NAME}-${i}"
  virtctl create vm --name "${VM_NAME}-${i}" --instancetype ci-baremetal --volume-import type:registry,url:docker://${VIRT_IMAGE},size:60Gi,pullmethod:node --cloud-init configdrive --cloud-init-user-data ${IGNITION_DATA} --run-strategy=Manual -n ${VM_NAMESPACE} >> "${SHARED_DIR}/vm.yaml"
done

# Create namespace if it does not exist (it will exist if multiple jobs run in same namespace)
if [[ "$(oc get ns ${VM_NAMESPACE} --ignore-not-found --kubeconfig="${VIRT_KUBECONFIG}")" == "" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Creating job namespace"
  oc create ns ${VM_NAMESPACE} --kubeconfig=${VIRT_KUBECONFIG}
fi

# Create VM (VM will not be running)
echo "$(date -u --rfc-3339=seconds) - Creating virtual machines"
oc create -f "${SHARED_DIR}/vm.yaml" --kubeconfig=${VIRT_KUBECONFIG}

# Update VM to have CI network
echo "$(date -u --rfc-3339=seconds) - Patching networking config into virtual machines"
for (( i=0; i<${BM_COUNT}; i++ )); do
  oc patch vm "${VM_NAME}-${i}" -n ${VM_NAMESPACE} --type=merge --patch-file ${VM_NETWORK_PATCH} --kubeconfig=${VIRT_KUBECONFIG}
done

# Start VM
echo "$(date -u --rfc-3339=seconds) - Starting virtual machines"
for (( i=0; i<${BM_COUNT}; i++ )); do
  virtctl start "${VM_NAME}-${i}" -n ${VM_NAMESPACE} --kubeconfig=${VIRT_KUBECONFIG}
done

# Monitor cluster for CSRs
approve_csrs

# Remove provider taint
for (( i=0; i<${BM_COUNT}; i++ )); do
  oc adm taint nodes "${VM_NAME}-${i}" node.cloudprovider.kubernetes.io/uninitialized=true:NoSchedule- --kubeconfig="${CLUSTER_KUBECONFIG}"
done

# Wait for node to be ready to prevent any interruption during the e2e tests
wait_for_node_ready

# Wait for all CO to be stable
wait_for_co_ready
