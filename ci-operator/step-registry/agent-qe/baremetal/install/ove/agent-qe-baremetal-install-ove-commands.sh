#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR

[ -z "${AUX_HOST}" ] && { echo "\$AUX_HOST is not filled. Failing."; exit 1; }

if [ "${DISCONNECTED}" == "true" ]; then
  [ ! -f "${SHARED_DIR}/proxy-conf.sh" ] && {
    echo "Proxy conf file is not found. Failing."
    exit 1
  }
  source "${SHARED_DIR}/proxy-conf.sh"
fi

CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")

HOST_ID=$(yq -r e -o=j -I=0 ".[0].host" "${SHARED_DIR}/hosts.yaml")
echo "$HOST_ID" >"${SHARED_DIR}"/host-id.txt

function mount_virtual_media() {
  local host="${1}"
  local iso_path="${2}"
  echo "Mounting the ISO image in #${host} via virtual media..."
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" mount.vmedia "${host}" "${iso_path}"
  local ret=$?
  if [ $ret -ne 0 ]; then
    echo "Failed to mount the ISO image in #${host} via virtual media."
    touch /tmp/virtual_media_mount_failure
    return 1
  fi
  return 0
}

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  (
   bmc_user=$(echo "$bmhost" | jq -r '.bmc_user')
   bmc_pass=$(echo "$bmhost" | jq -r '.bmc_pass')
   bmc_address=$(echo "$bmhost" | jq -r '.bmc_address')
   vendor=$(echo "$bmhost" | jq -r '.vendor')

   name=$(echo "$bmhost" | jq -r '.name')
   host=$(echo "$bmhost" | jq -r '.host')
   transfer_protocol_type=$(echo "$bmhost" | jq -r '.transfer_protocol_type // ""')
   if [ "${transfer_protocol_type}" == "cifs" ]; then
     IP_ADDRESS="$(dig +short "${AUX_HOST}")"
     iso_path="${IP_ADDRESS}/isos/${AGENT_ISO}"
   else
     # Assuming HTTP or HTTPS
     # IF _SNAPSHOT_ is not empty, this is a konflux job
     OVE_ISO_STORAGE_HOST=$(<"${CLUSTER_PROFILE_DIR}/ove_iso_storage_host")
     if [ ! -z "${SNAPSHOT}" ]; then
        iso_path="${transfer_protocol_type:-http}://${OVE_ISO_STORAGE_HOST}/${CLUSTER_NAME}.agent-ove.x86_64.iso"
     else
        iso_path="${transfer_protocol_type:-http}://${OVE_ISO_STORAGE_HOST}/${AGENT_ISO}"
     fi
   fi
   boot_selection="http"
   if [ "${vendor}" == "dell" ]; then
     mount_virtual_media "${host}" "${iso_path}"
     boot_selection="vcd"
   fi
   echo "Power on #${host} (${name})..."
   HOST_ADDRESS=$(<"${SHARED_DIR}"/cluster_name).$(<"${CLUSTER_PROFILE_DIR}"/base_domain)
   if ! timeout -s 9 15m ssh "${SSHOPTS[@]}" -p $((14000+"${HOST_ID}")) root@access."${HOST_ADDRESS}" prepare_host_for_boot \
          --host "$bmc_address" \
          --user "$bmc_user" \
          --password "$bmc_pass" \
          --vendor "$vendor" \
          --bootmode "$boot_selection" \
          --iso "$iso_path"; then
     echo "Failed to power on ${host} (${name})"
   fi
  ) &
  sleep 2s
done

wait

if [ -f /tmp/virtual_media_mount_failed ]; then
  echo "Failed to mount the ISO image in one or more hosts"
  exit 1
fi