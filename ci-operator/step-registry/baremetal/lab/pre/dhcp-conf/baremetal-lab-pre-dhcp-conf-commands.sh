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

BASE_DOMAIN="$(<"${CLUSTER_PROFILE_DIR}/base_domain")"
CLUSTER_NAME="$(<"${SHARED_DIR}/cluster_name")"
if [ "${SELF_MANAGED_NETWORK}" != "true" ]; then
  echo "Skipping the configuration of the DHCP."
  exit 0
fi

echo "Generating the DHCP/PXE config..."

DHCP_CONF="# DO NOT EDIT; BEGIN $CLUSTER_NAME
dhcp-option-force=tag:$CLUSTER_NAME,15,$CLUSTER_NAME.$BASE_DOMAIN
dhcp-option-force=tag:$CLUSTER_NAME,119,$CLUSTER_NAME.$BASE_DOMAIN"

for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  # shellcheck disable=SC2154
  if [ ${#mac} -eq 0 ] || [ ${#ip} -eq 0 ]; then
    echo "Error when parsing the Bare Metal Host metadata"
    exit 1
  fi
  DHCP_CONF="${DHCP_CONF}
dhcp-host=$mac,$ip,set:$CLUSTER_NAME,infinite"
done

DHCP_CONF="${DHCP_CONF}
# DO NOT EDIT; END $CLUSTER_NAME"

echo "Setting the DHCP/PXE config in the auxiliary host..."
timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- "'${DHCP_CONF}'" <<'EOF'
  echo -e "${1}" >> /opt/dnsmasq/etc/dnsmasq.conf
  systemctl restart dhcp
EOF
