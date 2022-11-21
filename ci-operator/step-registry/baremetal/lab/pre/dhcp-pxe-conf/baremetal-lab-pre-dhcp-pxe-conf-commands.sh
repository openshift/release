#!/bin/bash

# This script modifies the following files in the auxiliary host:
# - /opt/dhcpd/root/etc/dnsmasq.conf
# - /opt/tftpboot/grub.cfg-01-{hosts_mac}

if [ -n "${LOCAL_TEST}" ]; then
  # Setting LOCAL_TEST to any value will allow testing this script with default values against the ARM64 bastion @ RDU2
  # shellcheck disable=SC2155
  export NAMESPACE=test-ci-op AUX_HOST=openshift-qe-bastion.arm.eng.rdu2.redhat.com \
      SHARED_DIR=${SHARED_DIR:-$(mktemp -d)} CLUSTER_PROFILE_DIR=~/.ssh IPI=false SELF_MANAGED_NETWORK=true \
      INTERNAL_NET_IP=192.168.90.1
fi

set -o errexit
set -o pipefail
set -o nounset

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
EOF

if [ "${IPI}" = "true" ]; then
  echo "Skipping GRUB2 configuration (IPI install)"
  exit 0
fi

echo "Generating the GRUB2 config..."
GRUB_DIR=$(mktemp -d)

# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  flavor=${name%%-[0-9]*}

  cat > "${GRUB_DIR}/grub.cfg-01-$(echo "$mac" | tr ':' '-')" <<EOF
set timeout=5
set default=0
insmod efi_gop
insmod efi_uga
load_video
menuentry 'Install ($flavor)' {
    set gfx_payload=keep
    insmod gzio
    linux  /${NAMESPACE}/vmlinuz debug nosplash console=tty0 console=ttyS0,115200 ip=${baremetal_iface}:dhcp $(echo "$ipi_disabled_ifaces" | sed 's/;/:off ip=/g;s/^/ip=/;') coreos.live.rootfs_url=http://${INTERNAL_NET_IP}/${NAMESPACE}/rootfs.img ignition.config.url=http://${INTERNAL_NET_IP}/${NAMESPACE}/${flavor}-console-hook.ign ignition.firstboot ignition.platform.id=metal
    initrd /${NAMESPACE}/initramfs.img
}
EOF
done

echo "Uploading the GRUB2 config to the auxiliary host..."
scp "${SSHOPTS[@]}" "${GRUB_DIR}"/grub.cfg-01-* "root@${AUX_HOST}:/opt/tftpboot"
