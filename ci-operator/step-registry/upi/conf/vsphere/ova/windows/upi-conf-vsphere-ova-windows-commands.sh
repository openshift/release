#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

echo "$(date -u --rfc-3339=seconds) - Configuring govc exports."
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

# TODO: read VM template information from environment variable
VM_TEMPLATE="windows-golden-images/windows-server-2004-template"
VM_TEMPLATE_USERNAME="Administrator"

echo "$(date -u --rfc-3339=seconds) - Finding template ${VM_TEMPLATE} in vCenter..."
vm_info=$(govc vm.info -r "${VM_TEMPLATE}")

# check VM information
if [[ "${#vm_info}" -eq 0 ]]
then
    echo "$(date -u --rfc-3339=seconds) - Exiting, template ${VM_TEMPLATE} not found in vCenter"
    exit 1
fi

echo "$(date -u --rfc-3339=seconds) - Writing VM template name to file ${SHARED_DIR}/windows_vm_template.txt"
echo "${VM_TEMPLATE}" > "${SHARED_DIR}/windows_vm_template.txt"

echo "$(date -u --rfc-3339=seconds) - Writing VM template username to file ${SHARED_DIR}/windows_vm_template_username.txt"
echo "${VM_TEMPLATE_USERNAME}" > "${SHARED_DIR}/windows_vm_template_username.txt"
