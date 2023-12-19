#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

[ -z "${AUX_HOST}" ] && { echo "AUX_HOST is not filled. Failing."; exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

CLUSTER_NAME="$(<"${SHARED_DIR}/cluster_name")"

if [ "${SELF_MANAGED_NETWORK}" != "true" ]; then
  echo "Skipping the configuration of the DHCP."
  exit 0
fi

echo "Generating the GRUB2 config..."
GRUB_DIR=$(mktemp -d)

function join_by_semicolon() {
  local array_string="${1}"
  local prefix="${2}"
  local postfix="${3}"
  while [[ "${array_string}" = *\;* ]]; do
    # print initial part of string; then, remove it
    echo -n "${prefix}${array_string%%;*}${postfix} "
    array_string="${array_string#*;}"
  done
  # either the last or only one element is printed at the end
  if [ "${#array_string}" -gt 0 ]; then
    echo -n "${prefix}${array_string}${postfix} "
  fi
}

# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  flavor=${name%%-[0-9]*}
  mac_postfix=${mac//:/-}
  kargs="$(join_by_semicolon "$ipi_disabled_ifaces" "ip=" ":off")"
  kargs="$kargs$(join_by_semicolon "$console_kargs" "console=" "")"
  [ "$USE_CONSOLE_HOOK" == "true" ] && kargs="${kargs} ignition.config.url=http://${INTERNAL_NET_IP}/${CLUSTER_NAME}/$mac_postfix-console-hook.ign"
  cat > "${GRUB_DIR}/grub.cfg-01-${mac_postfix}" <<EOF
set timeout=5
set default=0
insmod efi_gop
insmod efi_uga
load_video
menuentry 'Install ($flavor)' {
    set gfx_payload=keep
    insmod gzio
    linux  /${CLUSTER_NAME}/vmlinuz_${arch} debug nosplash ip=${baremetal_iface}:dhcp $kargs coreos.live.rootfs_url=http://${INTERNAL_NET_IP}/${CLUSTER_NAME}/rootfs-${arch}.img ignition.firstboot ignition.platform.id=metal
    initrd /${CLUSTER_NAME}/initramfs_${arch}.img
}
EOF
done

echo "Uploading the GRUB2 config to the auxiliary host..."
scp "${SSHOPTS[@]}" "${GRUB_DIR}"/grub.cfg-01-* "root@${AUX_HOST}:/opt/dnsmasq/tftpboot"
