#!/bin/bash

set -o nounset
# let failures happen until this stabilizes
# set -o errexit
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - Deleting lease(s)..."
export KUBECONFIG=/var/run/vsphere-ibmcloud-ci/vsphere-capacity-manager-kubeconfig
oc get leases.vspherecapacitymanager.splat.io -l boskos-lease-id=${LEASED_RESOURCE}
oc delete leases.vspherecapacitymanager.splat.io -l boskos-lease-id=${LEASED_RESOURCE} -n vsphere-infra-helpers 
echo "$(date -u --rfc-3339=seconds) - Deleted lease(s)..."