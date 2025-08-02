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
[ -z "${architecture}" ] && { echo "\$architecture is not filled. Failing."; exit 1; }
[ -z "${workers}" ] && { echo "\$workers is not filled. Failing."; exit 1; }
[ -z "${masters}" ] && { echo "\$masters is not filled. Failing."; exit 1; }

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

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

yq -r e -o=j -I=0 ".[0].host" "${SHARED_DIR}/hosts.yaml" >"${SHARED_DIR}"/host-id.txt
BASE_DOMAIN=$(<"${CLUSTER_PROFILE_DIR}/base_domain")

# Patching the cluster_name again as the one set in the ipi-conf ref is using the ${UNIQUE_HASH} variable, and
# we might exceed the maximum length for some entity names we define
# (e.g., hostname, NFV-related interface names, etc...)
CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")

case "${BOOT_MODE}" in
"iso")
  ### Create ISO image
  for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
    # shellcheck disable=SC1090
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    if [[ "${name}" == *-a-* ]] && [ "${ADDITIONAL_WORKERS_DAY2}" == "true" ]; then
      # Do not mount image to additional workers if we need to run them as day2 (e.g., to test single-arch clusters based
      # on a single-arch payload migrated to a multi-arch cluster)
      continue
    fi
    if [ "${transfer_protocol_type}" == "cifs" ]; then
      IP_ADDRESS="$(dig +short "${AUX_HOST}")"
      iso_path="${IP_ADDRESS}/isos/agent-ove.x86_64.iso"
    else
      # Assuming HTTP or HTTPS
      iso_path="${transfer_protocol_type:-http}://${AUX_HOST}/agent-ove.x86_64.iso"
    fi
    mount_virtual_media "${host}" "${iso_path}"
  done

  wait
  if [ -f /tmp/virtual_media_mount_failed ]; then
    echo "Failed to mount the ISO image in one or more hosts"
    exit 1
  fi
;;
"pxe")
  ### Create pxe files
  echo -e "\nCreating PXE files..."
  oinst agent create pxe-files
  ### Copy the image to the auxiliary host
  echo -e "\nCopying the PXE files into the bastion host..."
  scp "${SSHOPTS[@]}" "${INSTALL_DIR}"/boot-artifacts/agent.*-vmlinuz* \
    "root@${AUX_HOST}:/opt/dnsmasq/tftpboot/${CLUSTER_NAME}/vmlinuz_${gnu_arch}"
  scp "${SSHOPTS[@]}" "${INSTALL_DIR}"/boot-artifacts/agent.*-initrd* \
    "root@${AUX_HOST}:/opt/dnsmasq/tftpboot/${CLUSTER_NAME}/initramfs_${gnu_arch}.img"
  scp "${SSHOPTS[@]}" "${INSTALL_DIR}"/boot-artifacts/agent.*-rootfs* \
    "root@${AUX_HOST}:/opt/html/${CLUSTER_NAME}/rootfs-${gnu_arch}.img"
;;
*)
  echo "Unknown install mode: ${BOOT_MODE}"
  exit 1
esac

proxy="$(<"${CLUSTER_PROFILE_DIR}/proxy")"
# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  if [[ "${name}" == *-a-* ]] && [ "${ADDITIONAL_WORKERS_DAY2}" == "true" ]; then
    # Do not power on the additional workers if we need to run them as day2 (e.g., to test single-arch clusters based
    # on a single-arch payload migrated to a multi-arch cluster)
    continue
  fi
  echo "Power on #${host} (${name})..."
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" prepare_host_for_boot "${host}" "${BOOT_MODE}"
done

wait

timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" \
    touch /var/builds/${CLUSTER_NAME}/preserve

echo "BASE_DOMAIN ${BASE_DOMAIN}"
echo "CLUSTER_NAME ${CLUSTER_NAME}"
#echo -e "\nForcing 2.5hours delay to allow instances to properly boot up (long PXE boot times & console-hook) - NOTE: unnecessary overtime will be reduced from total bootstrap time."
sleep 4h
cp "/tmp/kubeconfig" "${SHARED_DIR}/"
cp "/tmp/kubeadmin-password" "${SHARED_DIR}/"