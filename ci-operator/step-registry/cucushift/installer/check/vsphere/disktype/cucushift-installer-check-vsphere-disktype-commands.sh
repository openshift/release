#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source "${SHARED_DIR}/govc.sh"
source "${SHARED_DIR}/vsphere_context.sh"
export KUBECONFIG=${SHARED_DIR}/kubeconfig
declare vsphere_datacenter
declare vsphere_datastore
unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS
INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
check_result=0
disk_type="${DISK_TYPE:-thin}"

function check_disk_type() {
    local ret=0 vm_lists disk_file vm_disk_type 
    mapfile -t  vm_lists < <(govc ls /${vsphere_datacenter}/vm/${INFRA_ID})
    if (( ${#vm_lists[@]} == 0 )); then
        echo "vm_lists is empty, please check if vm still exits."
	return 1
    fi
    for vm in "${vm_lists[@]}"; do
        disk_file=$(govc vm.info -json /${vsphere_datacenter}/vm/${INFRA_ID}/${vm} | jq -r '.VirtualMachines[].Layout.Disk[].DiskFile[]' | awk  '{print $2}' | head -n1)
	vm_disk_type=$(govc datastore.disk.info -ds /${vsphere_datacenter}/datastore/${vsphere_datastore} ${disk_file} | grep Type | awk -F ':    '  '{print $2}')
	if [[ ${disk_type} == "thick" && ${vm_disk_type} == "preallocated" ]];then
	    echo "disk type for vm ${vm} is preallocated, matched with config value thick."
	elif [[ ${disk_type} == "eagerZeroedThick" && ${vm_disk_type} == "eagerZeroedThick" ]];then
	    echo "disk type for vm ${vm} is eagerZeroedThick, matched with config value eagerZeroedThick."
        elif [[ ${disk_type} == "thin" && ${vm_disk_type} == "thin" ]];then
	    echo "disk type for vm ${vm} is thin, matched with config value thin."
        else 
            echo "disk type for vm ${vm} is ${vm_disk_type}, but config value is ${disk_type}."
	    ret=1
	fi
    done
    return ${ret}
}
check_disk_type || check_result=1
exit ${check_result}
