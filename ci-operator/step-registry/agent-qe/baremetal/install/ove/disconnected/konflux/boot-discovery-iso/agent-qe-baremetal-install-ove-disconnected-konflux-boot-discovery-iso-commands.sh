#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR

[ -z "${AUX_HOST}" ] && { echo "\$AUX_HOST is not filled. Failing."; exit 1; }
[ -f "${SHARED_DIR}/discovery-iso-url" ] || { echo "Discovery ISO URL is missing."; exit 1; }

if [ "${DISCONNECTED}" == "true" ]; then
  [ ! -f "${SHARED_DIR}/proxy-conf.sh" ] && {
    echo "Proxy conf file is not found. Failing."
    exit 1
  }
  # shellcheck disable=SC1091
  source "${SHARED_DIR}/proxy-conf.sh"
fi

CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")
DISCOVERY_ISO_URL=$(<"${SHARED_DIR}/discovery-iso-url")
[ -n "${DISCOVERY_ISO_URL}" ] || { echo "Discovery ISO URL is empty."; exit 1; }
OVE_ISO_STORAGE_HOST=$(<"${CLUSTER_PROFILE_DIR}/ove_iso_storage_host")
echo "Booting hosts from ${DISCOVERY_ISO_URL}"

HOST_ID=$(yq -r e -o=j -I=0 ".[0].host" "${SHARED_DIR}/hosts.yaml")
echo "${HOST_ID}" > "${SHARED_DIR}/host-id.txt"

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

rm -f /tmp/virtual_media_mount_failure

mount_virtual_media() {
  local host="${1}"
  local iso_path="${2}"
  echo "Mounting the ISO image in #${host} via virtual media..."
  if ! timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" mount.vmedia "${host}" "${iso_path}"; then
    echo "Failed to mount the ISO image in #${host} via virtual media."
    touch /tmp/virtual_media_mount_failure
    return 1
  fi
}

for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  (
   bmc_user=$(echo "$bmhost" | jq -r '.bmc_user')
   bmc_pass=$(echo "$bmhost" | jq -r '.bmc_pass')
   bmc_address=$(echo "$bmhost" | jq -r '.bmc_address')
   vendor=$(echo "$bmhost" | jq -r '.vendor')
   name=$(echo "$bmhost" | jq -r '.name')
   host=$(echo "$bmhost" | jq -r '.host')
   iso_path="${DISCOVERY_ISO_URL}"
   boot_selection="http"
   if [ "${vendor}" == "dell" ]; then
     mount_virtual_media "${host}" "${iso_path}"
     boot_selection="vcd"
   fi
   echo "Power on #${host} (${name})..."
   CONTAINER_NAME="haproxy-${CLUSTER_NAME}"
   if ! timeout -s 9 15m ssh "${SSHOPTS[@]}" root@"${AUX_HOST}" \
        "nsenter -n -t \"\$(podman inspect -f '{{ .State.Pid }}' \"${CONTAINER_NAME}\")\" \
          ssh -o StrictHostKeyChecking=no root@\"${OVE_ISO_STORAGE_HOST}\" prepare_host_for_boot \
          --host \"${bmc_address}\" \
          --user \"${bmc_user}\" \
          --password \"${bmc_pass}\" \
          --vendor \"${vendor}\" \
          --bootmode \"${boot_selection}\" \
          --iso \"${iso_path}\""; then
     echo "Failed to power on ${host} (${name})"
   fi
  ) &
  sleep 2s
done

failed=0
wait || failed=1
if [ "${failed}" -ne 0 ] || [ -f /tmp/virtual_media_mount_failure ]; then
  echo "Failed to mount the ISO image in one or more hosts"
  exit 1
fi
