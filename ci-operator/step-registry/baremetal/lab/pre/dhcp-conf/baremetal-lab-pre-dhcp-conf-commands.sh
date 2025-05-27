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

# DHCP unique identifier (DUID)
DUID="00:03:00:01"

DHCP_CONF_OPTS="
tag:$CLUSTER_NAME,15,$CLUSTER_NAME.$BASE_DOMAIN
tag:$CLUSTER_NAME,119,$CLUSTER_NAME.$BASE_DOMAIN
"

DHCP_CONF=""

for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  # shellcheck disable=SC2154
  if [ ${#mac} -eq 0 ] || [ ${#ip} -eq 0 ]; then
    echo "Error when parsing the Bare Metal Host metadata"
    exit 1
  fi
  DHCP_CONF="${DHCP_CONF}
$mac,$ip,set:$CLUSTER_NAME,infinite"
  
  if [ "${ipv6_enabled:-}" == "true" ]; then
    # shellcheck disable=SC2154
    if [ ${#ipv6} -eq 0 ] || [ ${#name} -eq 0 ]; then
      echo "Error when parsing the Bare Metal Host metadata"
      exit 1
    fi
    DHCP_CONF="${DHCP_CONF}
id:$DUID:$mac,$name,[$ipv6],infinite"
  fi
done

DHCP_CONF="${DHCP_CONF}
$(<"${SHARED_DIR}/ipi_bootstrap_mac_address"),$(<"${SHARED_DIR}/ipi_bootstrap_ip_address"),set:$CLUSTER_NAME,infinite
id:$DUID:$(<"${SHARED_DIR}/ipi_bootstrap_mac_address"),$CLUSTER_NAME,[$(<"${SHARED_DIR}/ipi_bootstrap_ipv6_address")],infinite"

echo "Setting the DHCP/PXE config in the auxiliary host..."
timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "'${DHCP_CONF}'" "'${DHCP_CONF_OPTS}'" "'${CLUSTER_NAME}'" <<'EOF'
  echo -e "${1}" > /opt/dnsmasq/hosts/hostsdir/"${3}"
  echo -e "${2}" > /opt/dnsmasq/hosts/optsdir/"${3}"
EOF
