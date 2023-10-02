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

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

function umount_virtual_media() {
  ### Sushy doesn't support NFS as TransferProtcolType, and some servers' BMCs (in particular the ones of the arm64 servers)
  ##  are not 100% compliant with the Redfish standard. Therefore, relying on the raw redfish python library.
  bmc_address="${1}"
  bmc_username="${2}"
  bmc_password="${3}"
  echo "Unmounting the ISO image in ${bmc_address} via virtual media..."
  python3 - "${bmc_address}" "${bmc_username}" "${bmc_password}" <<'EOF'
import redfish
import sys
import time

bmc_address = sys.argv[1]
bmc_username = sys.argv[2]
bmc_password = sys.argv[3]

context = redfish.redfish_client(bmc_address, username=bmc_username, password=bmc_password)
context.login(auth=redfish.AuthMethod.BASIC)
response = context.get("/redfish/v1/Systems/")
manager = response.dict.get("Members")[0]["@odata.id"].split("/")[-1]
response = context.get(f"/redfish/v1/Systems/{manager}/VirtualMedia/")
#removable_disk = list(filter((lambda x: x["@odata.id"].find("CD") != -1),
#                             response.dict.get("Members")))[0]["@odata.id"].split("/")[-1]

print("Eject virtual media 1, if any")
response = context.post(
    f"/redfish/v1/Systems/{manager}/VirtualMedia/1/Actions/VirtualMedia.EjectMedia", body={})
print(response.text)
print(response.status)

print("Eject virtual media 2, if any")
response = context.post(
    f"/redfish/v1/Systems/{manager}/VirtualMedia/2/Actions/VirtualMedia.EjectMedia", body={})
print(response.text)
print(response.status)
EOF
  return $? # Return the exit code of the python script
}

function wait_for_power_down() {
  local bmc_address="${1}"
  local bmc_user="${2}"
  local bmc_pass="${3}"
  local name="${4}"
  local host_str="${bmc_address//.*/} (${name})"
  sleep 90
  local retry_max=40 # 15*40=600 (10 min)
  while [ $retry_max -gt 0 ] && ! ipmitool -I lanplus -H "$bmc_address" \
    -U "$bmc_user" -P "$bmc_pass" power status | grep -q "Power is off"; do
    echo "$host_str is not powered off yet... waiting"
    sleep 30
    retry_max=$(( retry_max - 1 ))
  done
  if [ $retry_max -le 0 ]; then
    echo -n "$host_str didn't power off successfully..."
    if [ -f "/tmp/$bmc_address" ]; then
      echo "$host_str kept powered on and needs further manual investigation..."
      return 1
    else
      # We perform the reboot at most twice to overcome some known BMC hardware failures
      # that sometimes keep the hosts frozen before POST.
      echo "retrying $host_str again to reboot..."
      touch "/tmp/$bmc_address"
      reset_host "$bmc_address" "$bmc_user" "$bmc_pass"
      return $?
    fi
  fi
  echo "$host_str is now powered off"
  return 0
}

function reset_host() {
  local bmc_address="${1}"
  local bmc_user="${2}"
  local bmc_pass="${3}"
  local name="${4}"
  local pdu_uri="${5}"
  echo "Rebooting host ${bmc_address//.*/} (${name})"
  ipmitool -I lanplus -H "$bmc_address" \
    -U "$bmc_user" -P "$bmc_pass" \
    power off || echo "Already off"
  if [ ! -f "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME" ]; then
    echo "Skipping the wipe step as not needed"
    return 0
  fi
  ipmitool -I lanplus -H "$bmc_address" \
    -U "$bmc_user" -P "$bmc_pass" \
    chassis bootparam set bootflag force_pxe options=PEF,watchdog,reset,power
  # If the host is not already powered off, the power on command can fail while the host is still powering off.
  # Let's retry the power on command multiple times to make sure the command is received in the correct state.
  for i in {1..10} max; do
    if [ "$i" == "max" ]; then
      echo "Failed to reset $bmc_address"
      return 1
    fi
    ipmitool -I lanplus -H "$bmc_address" \
      -U "$bmc_user" -P "$bmc_pass" \
      power on && break
    echo "Failed to power on $bmc_address, retrying..."
    sleep 5
  done

  if ! wait_for_power_down "$bmc_address" "$bmc_user" "$bmc_pass" "${name}"; then
    echo "$bmc_address" >> /tmp/failed
  fi
  [ -z "${pdu_uri}" ] && return 0
  pdu_host=${pdu_uri%%/*}
  pdu_socket=${pdu_uri##*/}
  pdu_creds=${pdu_host%%@*}
  pdu_host=${pdu_host##*@}
  pdu_user=${pdu_creds%%:*}
  pdu_pass=${pdu_creds##*:}
  # pub-priv key auth is not supported by the PDUs
  echo "${pdu_pass}" > /tmp/ssh-pass

  timeout -s 9 10m sshpass -f /tmp/ssh-pass ssh "${SSHOPTS[@]}" "${pdu_user}@${pdu_host}" <<EOF || true
olReboot $pdu_socket
quit
EOF
  if ! wait_for_power_down "$bmc_address" "$bmc_user" "$bmc_pass" "${name}"; then
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
  if [ ${#bmc_address} -eq 0 ] || [ ${#bmc_user} -eq 0 ] || [ ${#bmc_pass} -eq 0 ] || [ ${#name} -eq 0 ]; then
    echo "Error while unmarshalling hosts entries"
    exit 1
  fi
  reset_host "${bmc_address}" "${bmc_user}" "${bmc_pass}" "${name}" "${pdu_uri:-}" &
done

wait
echo "All children terminated."

# Eject virtual media from all hosts
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  # shellcheck disable=SC2154
  if [ "${#name}" -eq 0 ]; then
    echo "Unable to parse an entry in the hosts.yaml file"
  fi
  echo "Ejecting virtual media from ${name}"
  # shellcheck disable=SC2154
  umount_virtual_media "${bmc_address}" "${redfish_user}" "${redfish_password}"
done

if [ -s /tmp/failed ]; then
  echo The following nodes failed to power off:
  cat /tmp/failed
  exit 1
fi

exit 0
