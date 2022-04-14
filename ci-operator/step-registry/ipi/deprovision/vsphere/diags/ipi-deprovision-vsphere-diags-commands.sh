#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "${NAMESPACE}-${JOB_NAME_HASH}" > "${SHARED_DIR}"/clustername.txt
cluster_name=$(<"${SHARED_DIR}"/clustername.txt)

echo "$(date -u --rfc-3339=seconds) - Collecting vCenter performance data and alerts"
echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
# shellcheck source=/dev/null
declare cloud_where_run

source "${SHARED_DIR}/vsphere_context.sh"

function collect_diagnostic_data {
  set +e

  # assuming that if the install-status doesn't exist then something is
  # broken
  installer_exit_code=1
  # Check if install or bootstrap failed
  if [[ -f "${SHARED_DIR}/install-status.txt" ]]; then
      installer_exit_code=$(awk '{print $1}' "${SHARED_DIR}/install-status.txt")
  fi

  echo "$(date -u --rfc-3339=seconds) - installer exit code: ${installer_exit_code}"

  source "${SHARED_DIR}/govc.sh"
  vm_path="/${GOVC_DATACENTER}/vm/${cluster_name}"
  vcenter_state="${ARTIFACT_DIR}/vcenter_state"
  mkdir "${vcenter_state}"


  govc object.collect "/${GOVC_DATACENTER}/host" triggeredAlarmState &> "${vcenter_state}/host_alarms.log"
  clustervms=$(govc ls "${vm_path}-*")
  for vm in $clustervms; do
    vmname=$(echo "$vm" | rev | cut -d'/' -f 1 | rev)

    # skip template machine
    if [[ "$vmname" == *"rhcos"* ]]; then
        continue
    fi

    echo "Collecting alarms from $vm"
    govc object.collect "$vm" triggeredAlarmState &> "${vcenter_state}/${vmname}_alarms.log"
    echo "Collecting metrics from $vm"
    METRICS=$(govc metric.ls "$vm")
    govc metric.sample -json -n 60 "$vm" "$METRICS" &> "${vcenter_state}/${vmname}_metrics.json"

    # press ENTER on the console if screensaver is running
    echo "Keystoke enter in ${vmname} console"
    govc vm.keystrokes -vm.ipath="$vm" -c 0x28

    echo "$(date -u --rfc-3339=seconds) - capture console image from $vm"
    govc vm.console -vm.ipath="$vm" -capture "${vcenter_state}/${vmname}.png"

    if [[ "$installer_exit_code" -ne 0 ]]; then
        echo "Checking if VMware tools is running on ${vmname}"
        output=$(govc vm.ip -wait=0h0m10s -vm.ipath="$vm")
        if [[ -z "$output" ]]; then
            echo "VMware Tools is not running: ${vmname}"
            # VMware Tools is not running this RHCOS instance
            # didn't start up correctly in some way.

            echo "Powering off: ${vmname}"
            # power off machine
            govc vm.power -vm.ipath="$vm" -off -force=true

            echo "Removing network adapter: ${vmname}"
            # remove network adapter
            govc device.remove -vm.ipath="$vm" ethernet-0

            echo "Moving: ${vmname} to /${GOVC_DATACENTER}/vm/debug"
            # move to the debug folder
            govc object.mv "$vm" "/${GOVC_DATACENTER}/vm/debug"
        fi
    fi

  done
  first_vm=$(echo "${clustervms}" | cut -d" " -f1)
  target_hw_version=$(govc vm.info -json=true "${first_vm}" | jq -r .VirtualMachines[0].Config.Version)
  echo "{\"hw_version\":  \"${target_hw_version}\", \"cloud\": \"${cloud_where_run}\"}" > "${ARTIFACT_DIR}/runtime-config.json"

  set -e
}

collect_diagnostic_data
