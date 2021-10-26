#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - Upgrading VMs to hardware version 15"

export KUBECONFIG=${SHARED_DIR}/kubeconfig
cluster_name=$(<"${SHARED_DIR}"/clustername.txt)

function upgrade_vms_to_hardware_15() {
source "${SHARED_DIR}/govc.sh"
vm_path="/${GOVC_DATACENTER}/vm/${cluster_name}"

clustervms=$(govc ls "${vm_path}")
echo "$(date -u --rfc-3339=seconds) - Shutting down VMs"
govc vm.power -wait=true -s=true ${clustervms}

echo "$(date -u --rfc-3339=seconds) - Waiting for virtual machines to shutdown"
while [ true ]; do
  set +e
  POWERED_ON=$(govc vm.info -json=true ${clustervms} | jq -r .VirtualMachines[].Runtime.PowerState | grep poweredOn)  
  set -e

  if [ -z "${POWERED_ON}" ]; then
    echo "$(date -u --rfc-3339=seconds) - All virtual machines have shutdown"
    break
  fi  
  sleep 5
done

for vm in $clustervms; do
  echo "$(date -u --rfc-3339=seconds) - Upgrading ${vm} to hardware version 15"  
  govc vm.upgrade -version=15 -vm.ipath=${vm} 
done
echo "$(date -u --rfc-3339=seconds) - Powering on VMs"
govc vm.power -wait=true -on=true ${clustervms}
}

function wait_for_cluster_to_become_ready() {  
  # wait for API to come up and all operators to become ready
  echo "$(date -u --rfc-3339=seconds) - Waiting for cluster to become ready..."
  
  while [ true ]; do
    set +e
    oc wait co --all --for=condition=Available --timeout=30m
    if [ $? -eq 0 ]; then
      break
    fi    
    set -e        
    sleep 5
  done
}

upgrade_vms_to_hardware_15
wait_for_cluster_to_become_ready
