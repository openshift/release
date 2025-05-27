#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${CLUSTER_PROFILE_NAME:-}" != "vsphere-elastic" ]]; then
  echo "$(date -u --rfc-3339=seconds) - this step only runs with the vsphere-elastic cluster profile."
  exit 0
fi

VIRT_KUBECONFIG=/var/run/vault/vsphere-ibmcloud-config/vsphere-virt-kubeconfig
CLUSTER_KUBECONFIG=${SHARED_DIR}/kubeconfig
VM_NAMESPACE="${NAMESPACE}"

VM_NAME="$(oc get infrastructure cluster -o json --kubeconfig=${CLUSTER_KUBECONFIG} | jq -r '.status.infrastructureName')-bm"

# Clean up the VM.  The node can live in the cluster since it will be destroyed shortly.
echo "$(date -u --rfc-3339=seconds) - Stopping VM"
virtctl stop "${VM_NAME}" --force --grace-period=0 --kubeconfig="${VIRT_KUBECONFIG}"

echo "$(date -u --rfc-3339=seconds) - Deleting VM"
oc delete -f "${SHARED_DIR}/vm.yaml" --kubeconfig="${VIRT_KUBECONFIG}"

# Clean up namespace of Openshift Virt server
echo "$(date -u --rfc-3339=seconds) - Removing job namespace"
oc delete ns ${VM_NAMESPACE} --kubeconfig="${VIRT_KUBECONFIG}"