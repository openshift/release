#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${CLUSTER_PROFILE_NAME:-}" != "vsphere-elastic" ]]; then
  echo "$(date -u --rfc-3339=seconds) - this step only runs with the vsphere-elastic cluster profile."
  exit 0
fi

VIRT_KUBECONFIG=/var/run/vault/vsphere-ibmcloud-config/vsphere-virt-kubeconfig
CLUSTER_KUBECONFIG=~/Installs/multi-vc/auth/kubeconfig

VM_NAME="$(oc get infrastructure cluster -o json --kubeconfig=${CLUSTER_KUBECONFIG} | jq -r '.status.infrastructureName')-bm"

# Clean up the VM.  The node can live in the cluster since it will be destroyed shortly.
virtctl stop "${VM_NAME}" --force --grace-period=0 --kubeconfig="${VIRT_KUBECONFIG}"

oc delete -f vm.yaml --kubeconfig="${VIRT_KUBECONFIG}"