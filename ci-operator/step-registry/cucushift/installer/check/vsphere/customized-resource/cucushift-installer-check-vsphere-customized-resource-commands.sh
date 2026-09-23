#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
export KUBECONFIG=${SHARED_DIR}/kubeconfig
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS

function get_node_names() {
   local node_type=$1
   if [ -n "${node_type}" ]; then
      mapfile -t  node_lists < <(oc get node --no-headers | grep ${node_type} | awk '{print $1}')
   else
      mapfile -t  node_lists < <(oc get node --no-headers | awk '{print $1}')
   fi
  
   echo "${node_lists[*]}"
}

function check_master_nodes_number() {
    # shellcheck disable=SC2207
    #get node name
    master_lists=($(get_node_names "master"))

    if [[ ${#master_lists[@]} != "${CONTROL_PLANE_REPLICAS}" ]]; then
        echo "ERROR: The node number is not equal to ${CONTROL_PLANE_REPLICAS}"
        return 1
    else
        return 0
    fi
}

function check_worker_nodes_number() {
    # shellcheck disable=SC2207
    worker_lists=($(get_node_names "worker"))
    if [[ ${#worker_lists[@]} != "${COMPUTE_NODE_REPLICAS}" ]]; then
         echo "ERROR:The number of workers in Ready status is ${#worker_lists[@]}, should be ${COMPUTE_NODE_REPLICAS}"
         return 1
    else
         return 0
    fi

}
function check_node_resource() {
    local node_type=$1 expected_disk_size=$2 expected_cpu_number=$3 expected_memory_size=$4 status=0
    # shellcheck disable=SC2207
    node_lists=($(get_node_names $1))
    for node in "${node_lists[@]}"; do
         disk_size=$(govc vm.info -json ${node} | jq -r ".VirtualMachines[].Config.Hardware.Device[] | select(.CapacityInKB!=null) | .CapacityInKB" | head -n1)
         disk_size=$((${disk_size}/1024/1024))
	 num_cpu=$(govc vm.info -json ${node} | jq -r .VirtualMachines[].Config.Hardware.NumCPU)
	 memory_size=$(govc vm.info -json ${node} | jq -r .VirtualMachines[].Config.Hardware.MemoryMB)
         if [[ "${disk_size}" == "${expected_disk_size}" ]]; then
	    echo "INFO: get expected disk size!"
	 else
            echo "ERROR: get unexpected disk size, real disk size is ${disk_size}!"
	    status=1
	 fi
         if [[ "${num_cpu}" == "${expected_cpu_number}" ]]; then
            echo "INFO: get expected cpu number!"
         else
            echo "ERROR: get unexpected cpu number, real cpu number is ${num_cpu}!"
            status=1
         fi
         if [[ "${memory_size}" == "${expected_memory_size}" ]]; then
            echo "INFO: get expected memory size!"
         else
            echo "ERROR: get unexpected memory size, real memory size is ${memory_size}!"
            status=1
         fi
    done
    return ${status}
}

check_result=0
check_master_nodes_number
check_worker_nodes_number
echo "check worker resource"
check_node_resource "worker" "${COMPUTE_NODE_DISK_SIZE}" "${COMPUTE_NODE_CPU}" "${COMPUTE_NODE_MEMORY}" || check_result=1
echo "check master resource"
check_node_resource "master" "${CONTROL_PLANE_DISK_SIZE}" "${CONTROL_PLANE_CPU}" "${CONTROL_PLANE_MEMORY}" || check_result=1
exit ${check_result}

