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

# Check if namspace exists
if [ "$(oc get ns "${VM_NAMESPACE}" --kubeconfig="${VIRT_KUBECONFIG}" --ignore-not-found)" != "" ]; then
  # Check and see if BM node exists in
  if [ "$(oc get vm -n "${VM_NAMESPACE}" "${VM_NAME}" --kubeconfig="${VIRT_KUBECONFIG}" --ignore-not-found)" != "" ]; then
    # Clean up the VM.  The node can live in the cluster since it will be destroyed shortly.
    echo "$(date -u --rfc-3339=seconds) - Stopping VM"
    virtctl stop "${VM_NAME}" --force --grace-period=0 --kubeconfig="${VIRT_KUBECONFIG}"

    echo "$(date -u --rfc-3339=seconds) - Deleting VM"
    oc delete -f "${SHARED_DIR}/vm.yaml" --kubeconfig="${VIRT_KUBECONFIG}"
  fi

  # Clean up namespace of Openshift Virt server if no addition VMs are present from other test runs
  if [[ "$(oc get vm -n ${VM_NAMESPACE} --kubeconfig="${VIRT_KUBECONFIG}" -o name | wc -l)" -eq 0 ]]; then
    echo "$(date -u --rfc-3339=seconds) - Removing job namespace"
    oc delete ns ${VM_NAMESPACE} --kubeconfig="${VIRT_KUBECONFIG}"
  fi
fi