#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

check_result=0

if [[ -f ${CLUSTER_PROFILE_DIR}/secrets.sh ]]; then
   NUTANIX_AUTH_PATH=${CLUSTER_PROFILE_DIR}/secrets.sh
else
   NUTANIX_AUTH_PATH=/var/run/vault/nutanix/secrets.sh
fi

declare prism_central_host
declare prism_central_port
declare prism_central_username
declare prism_central_password
# shellcheck disable=SC1090
source "${NUTANIX_AUTH_PATH}"

pc_url="https://${prism_central_host}:${prism_central_port}"
api_ep="${pc_url}/api/nutanix/v3/vms/list"
un="${prism_central_username}"
pw="${prism_central_password}"

function check_cpus() {
   node_json=$1 cpus=$2
   vcpuSockets=$(echo "${node_json}" | jq '.entities[].status.resources.num_sockets')
   if [[ $vcpuSockets == "$cpus" ]]; then
      echo "Pass: passed to check node cpus: $vcpuSockets, expected: ${cpus}"
   else
      echo "Fail: failed to check node cpus: $vcpuSockets, expected: ${cpus}"
      check_result=$((check_result + 1))
   fi
}
function check_coresPerSocket() {
   node_json=$1 cores_per_socket=$2
   vcpusPerSocket=$(echo "${node_json}" | jq '.entities[].status.resources.num_vcpus_per_socket')
   if [[ $vcpusPerSocket == "$cores_per_socket" ]]; then
      echo "Pass: passed to check node coresPerSocket: $vcpusPerSocket, expected: ${cores_per_socket}"
   else
      echo "Fail: failed to check node coresPerSocket: $vcpusPerSocket, expected: ${cores_per_socket}"
      check_result=$((check_result + 1))
   fi
}
function check_memoryMiB() {
   node_json=$1 memory=$2
   memorySize=$(echo "${node_json}" | jq '.entities[].status.resources.memory_size_mib')
   if [[ $memorySize == "$memory" ]]; then
      echo "Pass: passed to check node memoryMiB: $memorySize, expected: ${memory}"
   else
      echo "Fail: failed to check node memoryMiB: $memorySize, expected: ${memory}"
      check_result=$((check_result + 1))
   fi
}
function check_diskSizeGiB() {
   node_json=$1 disk_size=$2
   disk_size_mib=$((disk_size*1024))
   systemDiskSize=$(echo "${node_json}" | jq '.entities[].status.resources.disk_list[]| select(.device_properties.device_type=="DISK") |.disk_size_mib')
   if [[ $systemDiskSize == "$disk_size_mib" ]]; then
      echo "Pass: passed to check node diskSizeGiB: $systemDiskSize, expected: ${disk_size_mib}"
   else
      echo "Fail: failed to check node diskSizeGiB: $systemDiskSize, expected: ${disk_size_mib}"
      check_result=$((check_result + 1))
   fi
}

IFS=' ' read -r -a master_nodes_list <<<"$(oc get nodes -l node-role.kubernetes.io/master= -ojson | jq -r '.items[].metadata.name' | xargs)"
if [[ ${#master_nodes_list[@]} == "${CONTROL_PLANE_REPLICAS}" ]]; then
   echo "Pass: passed to check control plane replicas as ${CONTROL_PLANE_REPLICAS}"
else
   echo "Fail: failed to check control plane replicas as ${CONTROL_PLANE_REPLICAS}"
   check_result=$((check_result + 1))
fi

for node in "${master_nodes_list[@]}"; do
   data="{
      \"filter\":\"vm_name==$node\"
   }"
   node_json=$(curl -ks -u "${un}":"${pw}" -X POST "${api_ep}" -H "Content-Type: application/json" -d @- <<<"${data}")
   check_cpus "$node_json" "$CONTROL_PLANE_CPU"
   check_coresPerSocket "$node_json" "$CONTROL_PLANE_CORESPERSOCKET"
   check_memoryMiB "$node_json" "$CONTROL_PLANE_MEMORY"
   check_diskSizeGiB "$node_json" "$CONTROL_PLANE_DISK_SIZE"
done

IFS=' ' read -r -a worker_nodes_list <<<"$(oc get nodes -l node-role.kubernetes.io/worker= -ojson | jq -r '.items[].metadata.name' | xargs)"
if [[ ${#worker_nodes_list[@]} == "${COMPUTE_REPLICAS}" ]]; then
   echo "Pass: passed to check worker replicas as ${COMPUTE_REPLICAS}"
else
   echo "Fail: failed to check worker replicas as ${COMPUTE_REPLICAS}"
   check_result=$((check_result + 1))
fi
for node in "${worker_nodes_list[@]}"; do
   data="{
      \"filter\":\"vm_name==$node\"
   }"
   node_json=$(curl -ks -u "${un}":"${pw}" -X POST "${api_ep}" -H "Content-Type: application/json" -d @- <<<"${data}")
   check_cpus "$node_json" "$COMPUTE_CPU"
   check_coresPerSocket "$node_json" "$COMPUTE_CORESPERSOCKET"
   check_memoryMiB "$node_json" "$COMPUTE_MEMORY"
   check_diskSizeGiB "$node_json" "$COMPUTE_DISK_SIZE"
done

exit "${check_result}"
