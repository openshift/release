#!/bin/bash

set -o nounset
# let failures happen until this stabilizes
# set -o errexit
set -o pipefail

if [[ "${CLUSTER_PROFILE_NAME:-}" != "vsphere-elastic" ]]; then
  echo "$(date -u --rfc-3339=seconds) - this step only runs with the vsphere-elastic cluster profile."
  exit 0
fi

echo "$(date -u --rfc-3339=seconds) - Deleting lease(s)..."
export KUBECONFIG=/var/run/vsphere-ibmcloud-ci/vsphere-capacity-manager-kubeconfig
oc get leases.vspherecapacitymanager.splat.io -l boskos-lease-group="${LEASED_RESOURCE}" -n vsphere-infra-helpers
oc delete leases.vspherecapacitymanager.splat.io -l boskos-lease-group="${LEASED_RESOURCE}" -n vsphere-infra-helpers
echo "$(date -u --rfc-3339=seconds) - Deleted lease(s)..."
