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

function wait_for_power_down() {
  local bmc_host="${1}"
  local bmc_port="${2}"
  local bmc_user="${3}"
  local bmc_pass="${4}"
  local ipxe_via_vmedia="${5}"
  local vendor="${6}"
  local host_str
  host_str="#${bmc_port##1[0-9]}"
  sleep 90
  local retry_max=40 # 15*40=600 (10 min)
  while [ $retry_max -gt 0 ] && ! ipmitool -I lanplus -H "${AUX_HOST}" -p "${bmc_port}" \
    -U "$bmc_user" -P "$bmc_pass" power status | grep -q "Power is off"; do
    echo "$host_str is not powered off yet... waiting"
    sleep 30
    retry_max=$(( retry_max - 1 ))
  done
  if [ $retry_max -le 0 ]; then
    echo -n "$host_str didn't power off successfully..."
    if [ -f "/tmp/$bmc_host.$bmc_port" ]; then
      echo "$host_str kept powered on and needs further manual investigation..."
      return 1
    else
      # We perform the reboot at most twice to overcome some known BMC hardware failures
      # that sometimes keep the hosts frozen before POST.
      echo "retrying $host_str again to reboot..."
      touch "/tmp/$bmc_host.$bmc_port"
      reset_host "$bmc_host" "$bmc_port" "$bmc_user" "$bmc_pass" "${ipxe_via_vmedia}" "${vendor}"
      return $?
    fi
  fi
  echo "$host_str is now powered off"
  return 0
}

function reset_host() {
  local bmc_address="${1}"
  local bmc_port="${2}"
  local bmc_user="${3}"
  local bmc_pass="${4}"
  local ipxe_via_vmedia="${5}"
  local vendor="${6}"
  local pdu_uri="${7:-}"
  local host="${bmc_port##1[0-9]}"
  host="${host##0}"
  echo "$host"
  echo "Rebooting host #${host}"
  ipmitool -I lanplus -H "${AUX_HOST}" -p "${bmc_port}" \
    -U "$bmc_user" -P "$bmc_pass" \
    power off || echo "Already off"
  ipmitool -I lanplus -H "${AUX_HOST}" -p "${bmc_port}" \
    -U "$bmc_user" -P "$bmc_pass" \
    chassis bootparam set bootflag force_pxe options=PEF,watchdog,reset,power
  if [ "$ipxe_via_vmedia" == "true" ]; then
    echo "Resetting host #${host} (via ipxe on vmedia)..."
    timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" mount.vmedia.ipxe "${host}"
  fi
  # If the host is not already powered off, the power on command can fail while the host is still powering off.
  # Let's retry the power on command multiple times to make sure the command is received in the correct state.
  for i in {1..10} max; do
    if [ "$i" == "max" ]; then
      echo "Failed to reset #$host"
      return 1
    fi
    ipmitool -I lanplus -H "${AUX_HOST}" -p "${bmc_port}" \
      -U "$bmc_user" -P "$bmc_pass" \
      power on && break
    echo "Failed to power on #$host, retrying..."
    sleep 5
  done

  if ! wait_for_power_down "$bmc_address" "$bmc_port" "$bmc_user" "$bmc_pass" "$ipxe_via_vmedia" "$vendor"; then
    echo "$bmc_host:$bmc_port" >> /tmp/failed
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
  if ! wait_for_power_down "$bmc_host" "$bmc_port" "$bmc_user" "$bmc_pass" "$ipxe_via_vmedia" "$vendor"; then
    echo "$bmc_host:$bmc_port" >> /tmp/failed
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
if [ ! -f "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME" ]; then
  echo "Skipping the wipe step as not needed"
else
  for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
    # shellcheck disable=SC1090
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    # shellcheck disable=SC2154
    if [ ${#bmc_forwarded_port} -eq 0 ] || [ ${#bmc_user} -eq 0 ] || [ ${#bmc_pass} -eq 0 ] \
      || [ ${#ipxe_via_vmedia} -eq 0 ]; then
      echo "Error while unmarshalling hosts entries"
      exit 1
    fi
    reset_host "${bmc_address}" "${bmc_forwarded_port}" "${bmc_user}" "${bmc_pass}" "${ipxe_via_vmedia}" \
      "${vendor}" "${pdu_uri:-}" &
  done
fi
wait
echo "All children terminated."

# Eject virtual media from all hosts
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  # shellcheck disable=SC2154
  if [ "${#name}" -eq 0 ] || [ "${ipxe_via_vmedia}" == "false" ] || [ "${#vendor}" -eq 0 ]; then
    echo "Unable to parse an entry in the hosts.yaml file"
  fi
  if [ "${ipxe_via_vmedia}" == "true" ]; then
    echo "The host #${host} requires an ipxe image to boot via vmedia in order to perform the pxe boot. The umount is ignored..."
    continue
  fi
  echo "Ejecting virtual media from ${name}"
  # shellcheck disable=SC2154
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" umount.vmedia "${host}"
done

if [ -s /tmp/failed ]; then
  echo The following nodes failed to power off:
  cat /tmp/failed
  exit 1
fi

exit 0
