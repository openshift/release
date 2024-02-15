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
DHCP_CONF_PXE="
tag:${CLUSTER_NAME},66,${AUX_HOST}
tag:${CLUSTER_NAME},67,pxe.disabled"

echo "Disabling the PXE server in the baremetal network for the hosts with tag ${CLUSTER_NAME}..."
timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- "'${DHCP_CONF_PXE}'" "'${CLUSTER_NAME}'" <<'EOF'
  echo "${1}" >> "/opt/dnsmasq/hosts/optsdir/${2}"
EOF
