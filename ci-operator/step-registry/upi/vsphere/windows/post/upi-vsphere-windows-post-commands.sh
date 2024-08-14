#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

echo "$(date -u --rfc-3339=seconds) - deprovisioning Windows VM on vSphere..."

echo "$(date -u --rfc-3339=seconds) - configuring govc exports..."
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS

# look for files ending with "_vsphere_e2e_vm.txt" in the shared dir
for f in "${SHARED_DIR}"/*_e2e_vsphere_vm.txt;
do
    if test -f "${f}"
    then
        # parse vm_name from filename
        vm_name=$(basename "${f}" "_e2e_vsphere_vm.txt")
        # destroy vm
        echo "$(date -u --rfc-3339=seconds) - destroying VM ${vm_name}..."
        govc vm.destroy "${vm_name}"
        # cleanup
        echo "$(date -u --rfc-3339=seconds) - $(rm -vf "${f}")"
    fi
done

# remove any created folders. Each line in the created_folders.txt file will contain the name of a folder
folder_file="${SHARED_DIR}/windows_vm_folders.txt"
if test -f "$folder_file"; then
    while read -r line; do
        echo "$(date -u --rfc-3339=seconds) - destroying folder ${line}..."
        govc object.destroy "${line}"
    done < $folder_file
    # cleanup
    echo "$(date -u --rfc-3339=seconds) - $(rm -vf "${folder_file}")"
fi
