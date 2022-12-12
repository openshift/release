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

BASE_DOMAIN=$(<"${CLUSTER_PROFILE_DIR}/base_domain")

if [ "${SELF_MANAGED_NETWORK}" != "true" ]; then
  echo "Skipping the configuration of the DHCP."
  exit 0
fi

echo "Generating the DHCP/PXE config..."

DHCP_CONF="#DO NOT EDIT; BEGIN $NAMESPACE
dhcp-option-force=tag:$NAMESPACE,15,$NAMESPACE.$BASE_DOMAIN
dhcp-option-force=tag:$NAMESPACE,119,$NAMESPACE.$BASE_DOMAIN"

for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  # shellcheck disable=SC2154
  if [ ${#mac} -eq 0 ] || [ ${#ip} -eq 0 ]; then
    echo "Error when parsing the Bare Metal Host metadata"
    exit 1
  fi
  DHCP_CONF="${DHCP_CONF}
dhcp-host=$mac,$ip,set:$NAMESPACE,infinite"
done

if [ "${IPI}" = "true" ]; then
  DHCP_CONF="${DHCP_CONF}
dhcp-boot=tag:${NAMESPACE},pxe.disabled"
fi

DHCP_CONF="${DHCP_CONF}
# DO NOT EDIT; END $NAMESPACE"

echo "Setting the DHCP/PXE config in the auxiliary host..."
timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- "'${DHCP_CONF}'" <<'EOF'
  echo -e "${1}" >> /opt/dhcpd/root/etc/dnsmasq.conf
  docker restart dhcpd
EOF

if [ "${IPI}" = "true" ]; then
  echo "Skipping GRUB2 configuration (IPI install)"
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
  cat > "${GRUB_DIR}/grub.cfg-01-${mac_postfix}" <<EOF
set timeout=5
set default=0
insmod efi_gop
insmod efi_uga
load_video
menuentry 'Install ($flavor)' {
    set gfx_payload=keep
    insmod gzio
    linux  /${NAMESPACE}/vmlinuz debug nosplash ip=${baremetal_iface}:dhcp $kargs coreos.live.rootfs_url=http://${INTERNAL_NET_IP}/${NAMESPACE}/rootfs.img ignition.config.url=http://${INTERNAL_NET_IP}/${NAMESPACE}/$mac_postfix-console-hook.ign ignition.firstboot ignition.platform.id=metal
    initrd /${NAMESPACE}/initramfs.img
}
EOF
done

echo "Uploading the GRUB2 config to the auxiliary host..."
scp "${SSHOPTS[@]}" "${GRUB_DIR}"/grub.cfg-01-* "root@${AUX_HOST}:/opt/tftpboot"
