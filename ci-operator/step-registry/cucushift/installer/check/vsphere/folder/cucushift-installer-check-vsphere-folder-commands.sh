#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

check_result=0

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
# shellcheck source=/dev/null
declare vsphere_datacenter
# shellcheck disable=SC1091
source "${SHARED_DIR}/vsphere_context.sh"


echo "$(date -u --rfc-3339=seconds) - Configuring govc exports..."
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

# These two environment variables are coming from vsphere_context.sh
# and govc.sh. The file they are assigned to is not available in this step.
unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS

FOLDER="/$vsphere_datacenter/vm/$vsphere_datacenter"
SUB_FOLDER="$FOLDER/${NAMESPACE}-${UNIQUE_HASH}"

nodes_list=$(oc get nodes -ojson | jq -r '.items[].metadata.name')
folder_vm_list=$(govc ls -t VirtualMachine "$SUB_FOLDER" | awk -F "/" '{print $6}')
for node in $nodes_list; do
    folder_check_result=1
    for folder_vm in $folder_vm_list; do
        if [[ "$folder_vm" == "$node" ]]; then
            echo "Pass: passed to check machine: $node folder $SUB_FOLDER"
            folder_check_result=0
            break
        fi
    done
    if [[ $folder_check_result == 1 ]]; then
        echo "Fail: fail to check machine: $node folder $SUB_FOLDER"
        check_result=$((check_result + 1))
    fi
done

template_check_result=1
for folder_vm in $folder_vm_list; do
    if [[ $folder_vm =~ ${NAMESPACE}-${UNIQUE_HASH}-.*-rhcos-generated-region-generated-zone ]]; then
        echo "Pass: passed to check rhcos template are created under folder $SUB_FOLDER"
        template_check_result=0
        break
    fi
done
if [[ $template_check_result == 1 ]]; then
    echo "Fail: fail to checo rhcos template are created under folder $SUB_FOLDER"
    check_result=$((check_result + 1))
fi

exit "${check_result}"
