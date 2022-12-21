#!/bin/bash

set -o nounset

if [ -z "${AUX_HOST}" ]; then
    echo "AUX_HOST is not filled. Failing."
    exit 1
fi

if [ "${SELF_MANAGED_NETWORK}" != "true" ]; then
  echo "Skipping the wipe step, as it's not implemented for non self-managed networks"
  exit 0
fi

if [ ! -f "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME" ]; then
  echo "Skipping the wipe step as not needed"
  exit 0
fi


function wait_for_power_down() {
  local bmc_address="${1}"
  local bmc_user="${2}"
  local bmc_pass="${3}"
  sleep 90
  local retry_max=40 # 15*40=600 (10 min)
  while [ $retry_max -gt 0 ] && ! ipmitool -I lanplus -H "$bmc_address" \
    -U "$bmc_user" -P "$bmc_pass" power status | grep -q "Power is off"; do
    echo "$bmc_address is not powered off yet... waiting"
    sleep 30
    retry_max=$(( retry_max - 1 ))
  done
  if [ $retry_max -le 0 ]; then
    echo -n "$bmc_address didn't power off successfully..."
    if [ -f "/tmp/$bmc_address" ]; then
      echo "$bmc_address kept powered on and needs further manual investigation..."
      return 1
    else
      # We perform the reboot at most twice to overcome some known BMC hardware failures
      # that sometimes keep the hosts frozen before POST.
      echo "retrying $bmc_address again to reboot..."
      touch "/tmp/$bmc_address"
      reset_host "$bmc_address" "$bmc_user" "$bmc_pass"
      return $?
    fi
  fi
  echo "$bmc_address is now powered off"
  return 0
}

function reset_host() {
  local bmc_address="${1}"
  local bmc_user="${2}"
  local bmc_pass="${3}"
  ipmitool -I lanplus -H "$bmc_address" \
    -U "$bmc_user" -P "$bmc_pass" \
    chassis bootparam set bootflag force_pxe options=PEF,watchdog,reset,power
  ipmitool -I lanplus -H "$bmc_address" \
    -U "$bmc_user" -P "$bmc_pass" \
    power reset
  if ! wait_for_power_down "$bmc_address" "$bmc_user" "$bmc_pass"; then
    echo "$bmc_address" >> /tmp/failed
  fi
}

# This step wipes the disk used to install coreos in the hosts.
# It exploits the default pxe/grub entry provided by the auxiliary host. This default entry boots into an initramfs that
# wipes the partition table and power down.
# Therefore, we expect baremetal-lab-post-dhcp-pxe-conf has already destroyed the (host,cluster)-specific boot config.
# Then, this step waits for the hosts to power down again at the end of the wiping process, so that the releasing step
# can happen safely, i.e., a concurrent reservation job has to wait until the disk of host X is wiped before being allowed
# to reserve X
touch /tmp/failed
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  # shellcheck disable=SC2154
  if [ ${#bmc_address} -eq 0 ] || [ ${#bmc_user} -eq 0 ] || [ ${#bmc_pass} -eq 0 ]; then
    echo "Error while unmarshalling hosts entries"
    exit 1
  fi
  reset_host "${bmc_address}" "${bmc_user}" "${bmc_pass}" &
done

wait
echo "All children terminated."

if [ -s /tmp/failed ]; then
  echo The following nodes failed to power off:
  cat /tmp/failed
  exit 1
fi

exit 0
