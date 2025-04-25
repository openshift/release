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
VM_NAME="$(oc get infrastructure cluster -o json --kubeconfig=${CLUSTER_KUBECONFIG} | jq -r '.status.infrastructureName')-bm"

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
installer_bin=$(which openshift-install)
VIRT_IMAGE=$("${installer_bin}" coreos print-stream-json | jq -r '.architectures.x86_64.images.kubevirt.image')
echo ${VIRT_IMAGE}

IGNITION_DATA=$(oc get secret worker-user-data -n openshift-machine-api -o json --kubeconfig=${CLUSTER_KUBECONFIG} | jq -r '.data.userData')

virtctl create vm --name ${VM_NAME} --instancetype virtualmachineinstancetype/manta --volume-containerdisk src:${VIRT_IMAGE} --cloud-init configdrive --cloud-init-user-data ${IGNITION_DATA} --run-strategy=Manual > vm.yaml

# Create VM (VM will not be running)
oc create -f vm.yaml

# Update VM to have CI network
oc patch vm ${VM_NAME} -n manta --type=merge --patch-file vm-network-patch.json --kubeconfig=${VIRT_KUBECONFIG}

# Start VM
virtctl start "${VM_NAME}" -n manta --kubeconfig=${VIRT_KUBECONFIG}

# Monitor cluster for CSRs
approve_csrs