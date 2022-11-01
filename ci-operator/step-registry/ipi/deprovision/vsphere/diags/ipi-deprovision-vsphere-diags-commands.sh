#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - Collecting vCenter performance data and alerts"
echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
# shellcheck source=/dev/null
declare cloud_where_run

source "${SHARED_DIR}/vsphere_context.sh"

function collect_diagnostic_data {
  set +e

  host_metrics="cpu.ready.summation
  cpu.usage.average
  cpu.usagemhz.average
  cpu.coreUtilization.average
  cpu.costop.summation
  cpu.demand.average
  cpu.idle.summation
  cpu.latency.average
  cpu.readiness.average
  cpu.reservedCapacity.average
  cpu.totalCapacity.average
  cpu.utilization.average
  datastore.datastoreIops.average
  datastore.datastoreMaxQueueDepth.latest
  datastore.datastoreReadIops.latest
  datastore.datastoreReadOIO.latest
  datastore.datastoreVMObservedLatency.latest
  datastore.datastoreWriteIops.latest
  datastore.datastoreWriteOIO.latest
  datastore.numberReadAveraged.average
  datastore.numberWriteAveraged.average
  datastore.siocActiveTimePercentage.average
  datastore.sizeNormalizedDatastoreLatency.average
  datastore.totalReadLatency.average
  datastore.totalWriteLatency.average
  disk.deviceLatency.average
  disk.maxQueueDepth.average
  disk.maxTotalLatency.latest
  disk.numberReadAveraged.average
  disk.numberWriteAveraged.average
  disk.usage.average
  mem.consumed.average
  mem.overhead.average
  mem.swapinRate.average
  mem.swapoutRate.average
  mem.usage.average
  mem.vmmemctl.average
  net.usage.average
  sys.uptime.latest"

  vm_metrics="cpu.ready.summation
  cpu.usage.average
  cpu.usagemhz.average
  cpu.readiness.average
  cpu.overlap.summation
  cpu.swapwait.summation
  cpu.system.summation
  cpu.used.summation
  cpu.wait.summation
  cpu.costop.summation
  cpu.demand.average
  cpu.entitlement.latest
  cpu.idle.summation
  cpu.latency.average
  cpu.maxlimited.summation
  cpu.run.summation
  datastore.read.average
  datastore.write.average
  datastore.maxTotalLatency.latest
  datastore.numberReadAveraged.average
  datastore.numberWriteAveraged.average
  datastore.totalReadLatency.average
  datastore.totalWriteLatency.average
  disk.maxTotalLatency.latest
  mem.consumed.average
  mem.overhead.average
  mem.swapinRate.average
  mem.swapoutRate.average
  mem.usage.average
  mem.vmmemctl.average
  net.usage.average
  sys.uptime.latest"

  source "${SHARED_DIR}/govc.sh"
  vcenter_state="${ARTIFACT_DIR}/vcenter_state"
  mkdir "${vcenter_state}"
  unset GOVC_DATACENTER
  unset GOVC_DATASTORE
  unset GOVC_RESOURCE_POOL

  echo "Gathering information from hosts and virtual machines associated with segment"

  IFS=$'\n' read -d '' -r -a all_hosts <<< "$(govc find . -type h -runtime.powerState poweredOn)"
  IFS=$'\n' read -d '' -r -a networks <<< "$(govc find -type=n -i=true -name ${LEASED_RESOURCE})"
  for network in "${networks[@]}"; do
          
      IFS=$'\n' read -d '' -r -a vms <<< "$(govc find . -type m -runtime.powerState poweredOn -network $network)"            
      if [ -z ${vms:-} ]; then
        govc find . -type m -runtime.powerState poweredOn -network $network
        echo "No VMs found"
        continue
      fi
      for vm in "${vms[@]}"; do        
          datacenter=$(echo "$vm" | cut -d'/' -f 2)
          vm_host="$(govc vm.info -dc="${datacenter}" ${vm} | grep "Host:" | awk -F "Host:         " '{print $2}')"
          
          if [ ! -z "${vm_host}" ]; then
              hostname=$(echo "${vm_host}" | rev | cut -d'/' -f 1 | rev)
              if [ ! -f "${vcenter_state}/${hostname}.metrics.txt" ]; then                  
                  full_hostpath=$(for host in "${all_hosts[@]}"; do echo ${host} | grep ${vm_host}; done)                  
                  if [ -z "${full_hostpath:-}" ]; then
                    continue
                  fi
                  echo "Collecting Host metrics for ${vm_host}"
                  hostname=$(echo "${vm_host}" | rev | cut -d'/' -f 1 | rev)
                  govc metric.sample -dc="${datacenter}" -d=80 -n=60 ${full_hostpath} ${host_metrics} > ${vcenter_state}/${hostname}.metrics.txt
                  govc metric.sample -dc="${datacenter}" -d=80 -n=60 -t=true -json=true ${full_hostpath} ${host_metrics} > ${vcenter_state}/${hostname}.metrics.json
                  govc object.collect -dc="${datacenter}" "${vm_host}" triggeredAlarmState &> "${vcenter_state}/${hostname}_alarms.log"
              fi
          fi
          echo "Collecting VM metrics for ${vm}"
          vmname=$(echo "$vm" | rev | cut -d'/' -f 1 | rev)          
          govc metric.sample -dc="${datacenter}" -d=80 -n=60 $vm ${vm_metrics} > ${vcenter_state}/${vmname}.metrics.txt
          govc metric.sample -dc="${datacenter}" -d=80 -n=60 -t=true -json=true $vm ${vm_metrics} > ${vcenter_state}/${vmname}.metrics.json

          echo "Collecting alarms from ${vm}"
          govc object.collect -dc="${datacenter}" "${vm}" triggeredAlarmState &> "${vcenter_state}/${vmname}_alarms.log"    

          # press ENTER on the console if screensaver is running
          echo "Keystoke enter in ${vmname} console"
          govc vm.keystrokes -dc="${datacenter}" -vm.ipath="${vm}" -c 0x28

          echo "$(date -u --rfc-3339=seconds) - capture console image from $vm"
          govc vm.console -dc="${datacenter}" -vm.ipath="${vm}" -capture "${vcenter_state}/${vmname}.png"       
      done
  done
  target_hw_version=$(govc vm.info -json=true "${vms[0]}" | jq -r .VirtualMachines[0].Config.Version)
  echo "{\"hw_version\":  \"${target_hw_version}\", \"cloud\": \"${cloud_where_run}\"}" > "${ARTIFACT_DIR}/runtime-config.json"

  set -e
}

collect_diagnostic_data
