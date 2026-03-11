#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR

[ -z "${AUX_HOST}" ] && { echo "\$AUX_HOST is not filled. Failing."; exit 1; }
[ -z "${AGENT_ISO}" ] && { echo "\$AGENT_ISO is not filled. Failing."; exit 1; }
[ ! -f "${SHARED_DIR}/proxy-conf.sh" ] && { echo "Proxy conf file is not found. Failing."; exit 1; }

source "${SHARED_DIR}/proxy-conf.sh"
yq -r e -o=j -I=0 ".[0].host" "${SHARED_DIR}/hosts.yaml" >"${SHARED_DIR}"/host-id.txt

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
   name=$(echo "$bmhost" | jq -r '.name')
   host=$(echo "$bmhost" | jq -r '.host')
   transfer_protocol_type=$(echo "$bmhost" | jq -r '.transfer_protocol_type // ""')
   if [ "${transfer_protocol_type}" == "cifs" ]; then
     IP_ADDRESS="$(dig +short "${AUX_HOST}")"
     iso_path="${IP_ADDRESS}/isos/${AGENT_ISO}"
   else
     # Assuming HTTP or HTTPS
     iso_path="${transfer_protocol_type:-http}://${AUX_HOST}/${AGENT_ISO}"
   fi
   mount_virtual_media "${host}" "${iso_path}"

   echo "Power on #${host} (${name})..."
   if ! timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" prepare_host_for_boot "${host}" "${BOOT_MODE}"; then
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