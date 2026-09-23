#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
source "${SHARED_DIR}/govc.sh"
source "${SHARED_DIR}/vsphere_context.sh"
export KUBECONFIG=${SHARED_DIR}/kubeconfig
declare vsphere_datacenter
INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
check_result=0

function check_vm_tags() {
    local ret=0
    mapfile -t  node_lists < <(oc get node --no-headers | awk '{print $1}')
    
    for node in "${node_lists[@]}"; do
        vm_info=$(govc vm.info -json /${vsphere_datacenter}/vm/${INFRA_ID}/${node} | jq -r '.VirtualMachines[].Self.Value')
        printf '%s' "${USER_TAGS:-}" | while read -r tag
        do
 	    if	[[ -n "$(govc tags.attached.ls ${tag} | grep ${vm_info})" ]];then
	        echo "the vm ${node} under tag ${tag} is found, check successful."
	    else
		ret=1
		echo "the vm ${node} under tag ${tag} not found, check failed."
            fi
	done
    done 
    return ${ret}

}

check_vm_tags || check_result=1
exit ${check_result}

