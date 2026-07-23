#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR
# Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' TERM ERR

[ -z "${AUX_HOST}" ] && { echo "\$AUX_HOST is not filled. Failing."; exit 1; }

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

function mount_virtual_media() {
  local host="${1}"
  local iso_path="${2}"
  echo "Mounting the ISO image in #${host} via virtual media..."
  # Mount the agent configuration ISO image in the second Virtual Media Slot (1)
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" mount.vmedia "${host}" "${iso_path}" "1"
  local ret=$?
  if [ $ret -ne 0 ]; then
    echo "Failed to mount the ISO image in #${host} via virtual media."
    touch /tmp/virtual_media_mount_failure
    return 1
  fi
  return 0
}

# Patching the cluster_name again as the one set in the ipi-conf ref is using the ${UNIQUE_HASH} variable, and
# we might exceed the maximum length for some entity names we define
# (e.g., hostname, NFV-related interface names, etc...)
CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")

case "${BOOT_MODE}" in
"iso")
  echo -e "\nMounting the agent configuration ISO image in the hosts via virtual media in slot 2"
  # shellcheck disable=SC2154
  for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
    # shellcheck disable=SC1090
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    if [ "${transfer_protocol_type}" == "cifs" ]; then
      IP_ADDRESS="$(dig +short "${AUX_HOST}")"
      iso_path="${IP_ADDRESS}/isos/${CLUSTER_NAME}/${AGENT_CONFIGURATION_IMAGE_NAME}"
    else
      iso_path="${transfer_protocol_type:-http}://${AUX_HOST}/${CLUSTER_NAME}/${AGENT_CONFIGURATION_IMAGE_NAME}"
    fi
    mount_virtual_media "${host}" "${iso_path}" &
  done

  wait
  if [ -f /tmp/virtual_media_mount_failed ]; then
    echo "Failed to mount the agent configuration ISO image in one or more hosts"
    exit 1
  fi
;;
*)
  echo "Unknown install mode: ${BOOT_MODE}"
  exit 1
esac

echo -e "\nForcing 10 minutes delay to allow instances to properly configure using configured agent image"
sleep 600
