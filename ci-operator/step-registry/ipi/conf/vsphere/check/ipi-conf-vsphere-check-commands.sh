#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - failed to acquire lease"
    exit 1
fi

TFVARS_PATH=/var/run/secrets/ci.openshift.io/cluster-profile/vmc.secret.auto.tfvars
vsphere_user=$(grep -oP 'vsphere_user\s*=\s*"\K[^"]+' ${TFVARS_PATH})
vsphere_password=$(grep -oP 'vsphere_password\s*=\s*"\K[^"]+' ${TFVARS_PATH})

echo "$(date -u --rfc-3339=seconds) - Creating govc.sh file..."
cat >> "${SHARED_DIR}/govc.sh" << EOF
export GOVC_URL=vcenter.sddc-44-236-21-251.vmwarevmc.com
export GOVC_USERNAME="${vsphere_user}"
export GOVC_PASSWORD="${vsphere_password}"
export GOVC_INSECURE=1
export GOVC_DATACENTER=SDDC-Datacenter
export GOVC_DATASTORE=WorkloadDatastore
EOF

# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

echo "$(date -u --rfc-3339=seconds) - Find virtual machines attached to ${LEASED_RESOURCE} and destroy"

# 1. Get the OpaqueNetwork (NSX-T port group) which is listed in LEASED_RESOURCE.
# 2. Select the virtual machines attached to network
# 3. list the path to the virtual machine via the managed object reference
# 4. skip the templates with ova
# 5. Power off and delete the virtual machine

govc ls -json -t OpaqueNetwork "/SDDC-Datacenter/network/${LEASED_RESOURCE}" |\
    jq '.elements[]?.Object.Vm[]?.Value' |\
    xargs -I {} --no-run-if-empty govc ls -json -L VirtualMachine:{} |\
    jq '.elements[].Path | select(contains("ova") | not)' |\
    xargs -I {} --no-run-if-empty govc vm.destroy {}


# The release controller starts four CI jobs concurrently: UPI, IPI, parallel and serial
# We are currently having high CPU ready time in the vSphere CI cluster and this
# does not help the situation. For periodics create a slight random delay
# before continuing job progression.

if [[ "${JOB_TYPE}" = "periodic" ]]; then
    sleep "$(( RANDOM % 240 + 60 ))"s
fi
