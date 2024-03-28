#!/bin/bash

set -x
export KUBECONFIG=${SHARED_DIR}/kubeconfig
source "${SHARED_DIR}/govc.sh"
function get_node_names() {
   local node_type=$1
   if [ -n "${node_type}" ]; then
      mapfile -t  node_lists < <(oc get node --no-headers | grep ${node_type} | awk '{print $1}')
   else
      mapfile -t  node_lists < <(oc get node --no-headers | awk '{print $1}')
   fi
  
   echo ${node_lists[*]}
}

function check_master_nodes_number() {

#get node name
master_lists=$(get_node_names "master")
IFS=" "
read -r -a master_lists <<< "${master_lists}"
#get etcd pods names
infra_id=$(oc get -o jsonpath='{.status.infrastructureName}' infrastructure cluster)
mapfile -t etcd_pods_names < <(oc get pod -n openshift-etcd | grep Running | grep etcd-${infra_id} | awk '{print $1}')

  if [[ ${#master_lists[@]} != "${#etcd_pods_names[@]}" && ${#etcd_pods_names[@]} != "${CONTROL_PLANE_REPLICAS}" ]]; then
      echo "ERROR: The node number and etcd pod number are not equal to ${CONTROL_PLANE_REPLICAS}"
      return 1
  fi
  count=0
   echo "--------"
  echo ${master_lists[0]}
  echo ${etcd_pods_names[0]}
  for node in "${master_lists[@]}"; do
      etcd="etcd-${node}"
      echo "test ${etcd_pods_names[*]}"
      echo "test1 ${etcd}"
      if [[ ${etcd_pods_names[*]} =~ ${etcd} ]]; then
	  count=$(($count+1))
      fi
  done
  echo "the final count is${count}"
  if [[ "${count}" != "${CONTROL_PLANE_REPLICAS}" ]] ; then
     echo "ERROR: The number of masters in Ready status is ${#master_lists[@]}, etcd pod number is ${#etcd_pods_names[@]} should be ${CONTROL_PLANE_REPLICAS}" 
     return 1
  else 
     return 0
  fi  
}

function check_worker_nodes_number() {
worker_lists=$(get_node_names "worker")
IFS=" "
read -r -a worker_lists <<< "${worker_lists}"
if [[ ${#worker_lists[@]} != "${COMPUTE_NODE_REPLICAS}" ]]; then
     echo "ERROR:The number of workers in Ready status is ${#worker_lists[@]}, should be ${COMPUTE_NODE_REPLICAS}"
     return 1
else
     return 0
fi

}
function check_node_resource() {
    tmp=$(get_node_names $1)
    IFS=" "
    read -r -a node_lists <<< "${tmp}"
    for node in "${node_lists[@]}"; do
      if [[ "$2" == "Disk" ]]; then
         act_val=$(govc vm.info -json ${node} | jq -r ".VirtualMachines[].Config.Hardware.Device[] | select(.CapacityInKB!=null) | .CapacityInKB")
      else 
         act_val=$(govc vm.info -json ${node} | jq -r .VirtualMachines[].Config.Hardware.$2)
      fi
      if [[ "$2" == "Disk" ]]; then
	 act_val=`expr ${act_val}/1024/1024`
      fi
      if [[ "$3" != "${act_val}" ]]; then
	  echo "ERROR The node ${node} has ${act_val} cpu, should be $3 cpu"
	  return 1
      fi
    done
    return 0
}

function check_machineset() {
    num_replicas=$(oc get machineset -n openshift-machine-api -o json | jq .items[].spec.replicas)
    disk_size=$(oc get machineset -n openshift-machine-api -o json | jq .items[].spec.template.spec.providerSpec.value.diskGiB)
    memory_size=$(oc get machineset -n openshift-machine-api -o json | jq .items[].spec.template.spec.providerSpec.value.memoryMiB)
    num_cpu=$(oc get machineset -n openshift-machine-api -o json | jq .items[].spec.template.spec.providerSpec.value.numCPUs)
    if [[ "$1" == "${num_replicas}" && "$2" == "${disk_size}" && "$4" == "${memory_size}" && "$3" == "${num_cpu}" ]]; then
       echo "INFO:Machineset has correct value for replicas, disk size, memory and cpu!"
       return 0
    else
       echo "ERROR:Machineset has incorrect value for replicas, disk size, memory and cpu!"
       return 1
    fi
}

check_master_nodes_number
check_worker_nodes_number
check_node_resource "worker" "NumCPU" "${COMPUTE_NODE_CPU}"
if [[ "$?" == 1 ]] ;then
   echo "ERROR:Worker node cpu check failed!"
fi
check_node_resource "master" "NumCPU" "${CONTROL_PLANE_CPU}"
if [[ "$?" == 1 ]] ;then
   echo "ERROR:Master node cpu check failed!"
fi
check_node_resource "worker" "MemoryMB" "${COMPUTE_NODE_MEMORY}"
if [[ "$?" == 1 ]] ;then
   echo "ERROR:Worker node memory check failed!"
fi
check_node_resource "master" "MemoryMB" "${CONTROL_PLANE_MEMORY}"
if [[ "$?" == 1 ]] ;then
   echo "ERROR:Master node memory check failed!"
fi
check_node_resource "worker" "Disk" "${COMPUTE_NODE_DISK_SIZE}"
if [[ "$?" == 1 ]] ;then
   echo "Worker node disk check failed!"
fi
check_node_resource "master" "Disk" "${CONTROL_PLANE_DISK_SIZE}"
if [[ "$?" == 1 ]] ;then
   echo "ERROR:Master node disk check failed!"
fi
check_machineset "${COMPUTE_NODE_REPLICAS}" "${COMPUTE_NODE_DISK_SIZE}" "${COMPUTE_NODE_CPU}" "${COMPUTE_NODE_MEMORY}"
if [[ "$?" == 1 ]] ;then
   echo "ERROR:The value in machineset is not correct!"
fi
