#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

declare vsphere_portgroup

# shellcheck source=/dev/null
source "${SHARED_DIR}/vsphere_context.sh"
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"



echo "$(date -u --rfc-3339=seconds) - Find virtual machines attached to ${vsphere_portgroup} and destroy"

# 1. Get the OpaqueNetwork (NSX-T port group) which is listed in LEASED_RESOURCE.
# 2. Select the virtual machines attached to network
# 3. list the path to the virtual machine via the managed object reference
# 4. skip the templates with ova
# 5. Power off and delete the virtual machine
govc ls -json "/${GOVC_DATACENTER}/network/${vsphere_portgroup}" |\
    jq '.elements[]?.Object.Vm[]?.Value' |\
    xargs -I {} --no-run-if-empty govc ls -json -L VirtualMachine:{} |\
    jq '.elements[].Path | select((contains("ova") or test("\\bci-segment-[0-9]?[0-9]?[0-9]-bastion\\b")) | not)' |\
    xargs -I {} --no-run-if-empty govc vm.destroy {}


# The release controller starts four CI jobs concurrently: UPI, IPI, parallel and serial
# We are currently having high CPU ready time in the vSphere CI cluster and this
# does not help the situation. For periodics create a slight random delay
# before continuing job progression.
if [[ "${JOB_TYPE}" = "periodic" ]]; then
    sleep "$(( RANDOM % 240 + 60 ))"s
fi
