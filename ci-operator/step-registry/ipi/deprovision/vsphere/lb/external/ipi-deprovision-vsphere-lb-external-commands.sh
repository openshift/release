#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

if [ ! -f "$SHARED_DIR/external_lb" ]; then
    echo "$(date -u --rfc-3339=seconds) - external load balancer not provisioned..."
    exit 1
fi

cluster_name=${NAMESPACE}-${UNIQUE_HASH}

echo "$(date -u --rfc-3339=seconds) - Deprovisioning external load balancer..."

# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

echo "$(date -u --rfc-3339=seconds) - Checking if external load balancer VM is provisioned..."

LB_VMNAME="${cluster_name}-lb"
if [[ "$(govc vm.info "${LB_VMNAME}" | wc -c)" -ne 0 ]]
then
    echo "$(date -u --rfc-3339=seconds) - powering off external load balancer VM..."
    govc vm.power -off=true ${LB_VMNAME}
    echo "$(date -u --rfc-3339=seconds) - destroying external load balancer VM..."
    govc vm.destroy ${LB_VMNAME}
fi
