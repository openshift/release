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
    if [[ $CSR_COUNT == 2 ]]; then
        return 0
    fi
    sleep 15
  done
}


# Generate YAML for creation VM
echo "$(date -u --rfc-3339=seconds) - Generating ignition data"
installer_bin=$(which openshift-install)
VIRT_IMAGE=$("${installer_bin}" coreos print-stream-json | jq -r '.architectures.x86_64.images.kubevirt.image')
echo ${VIRT_IMAGE}

IGNITION_DATA=$(oc get secret worker-user-data -n openshift-machine-api -o json --kubeconfig=${CLUSTER_KUBECONFIG} | jq -r '.data.userData')

echo "$(date -u --rfc-3339=seconds) - Generating virtual machine yaml"
virtctl create vm --name ${VM_NAME} --instancetype ci-baremetal --volume-containerdisk src:${VIRT_IMAGE} --cloud-init configdrive --cloud-init-user-data ${IGNITION_DATA} --run-strategy=Manual -n ${VM_NAMESPACE} > "${SHARED_DIR}/vm.yaml"

# Create VM (VM will not be running)
echo "$(date -u --rfc-3339=seconds) - Creating virtual machine"
oc create ns ${VM_NAMESPACE} --kubeconfig=${VIRT_KUBECONFIG}
oc create -f "${SHARED_DIR}/vm.yaml" --kubeconfig=${VIRT_KUBECONFIG}

# Update VM to have CI network
echo "$(date -u --rfc-3339=seconds) - Patching networking config into virtual machine"
oc patch vm ${VM_NAME} -n ${VM_NAMESPACE} --type=merge --patch-file ${VM_NETWORK_PATCH} --kubeconfig=${VIRT_KUBECONFIG}

# Start VM
echo "$(date -u --rfc-3339=seconds) - Starting virtual machine"
virtctl start "${VM_NAME}" -n ${VM_NAMESPACE} --kubeconfig=${VIRT_KUBECONFIG}

# Monitor cluster for CSRs
approve_csrs

# Remove provider taint
oc adm taint nodes ${VM_NAME} node.cloudprovider.kubernetes.io/uninitialized=true:NoSchedule- --kubeconfig="${CLUSTER_KUBECONFIG}"