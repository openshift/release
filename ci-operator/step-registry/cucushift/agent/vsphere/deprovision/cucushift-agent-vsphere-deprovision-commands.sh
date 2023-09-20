#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - failed to acquire lease"
    exit 1
fi

source "${SHARED_DIR}/govc.sh"

declare vsphere_portgroup
source "${SHARED_DIR}/vsphere_context.sh"

echo "$(date -u --rfc-3339=seconds) - Find virtual machines attached to ${vsphere_portgroup} and destroy"

govc ls -json "/${GOVC_DATACENTER}/network/${vsphere_portgroup}" |
    jq '.elements[]?.Object.Vm[]?.Value' |
    xargs -I {} --no-run-if-empty govc ls -json -L VirtualMachine:{} |
    jq '.elements[].Path | select((contains("ova") or test("\\bci-segment-[0-9]?[0-9]?[0-9]-bastion\\b")) | not)' |
    xargs -I {} --no-run-if-empty govc vm.destroy {}

agent_iso=$(<"${SHARED_DIR}"/agent-iso.txt)
echo "$(date -u --rfc-3339=seconds) - Removing ${agent_iso} from iso-datastore.."

govc datastore.rm -ds "${GOVC_DATASTORE}" agent-installer-isos/"${agent_iso}"
