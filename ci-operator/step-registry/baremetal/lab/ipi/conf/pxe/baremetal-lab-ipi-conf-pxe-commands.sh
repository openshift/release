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

echo "Disabling the PXE server in the baremetal network..."
DHCP_CONF="#DO NOT EDIT; BEGIN ${CLUSTER_NAME}
dhcp-boot=tag:${CLUSTER_NAME},pxe.disabled
# DO NOT EDIT; END ${CLUSTER_NAME}"

echo "Restart the DHCP/PXE container in the auxiliary host..."

timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- "'${DHCP_CONF}'" <<'EOF'
  echo -e "${1}" >> /opt/dnsmasq/etc/dnsmasq.conf
  systemctl restart dhcp
EOF
