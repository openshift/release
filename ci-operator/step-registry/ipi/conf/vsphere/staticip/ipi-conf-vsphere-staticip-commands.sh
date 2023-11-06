#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
# shellcheck source=/dev/null
declare dns_server
declare vlanid
declare primaryrouterhostname
source "${SHARED_DIR}/vsphere_context.sh"

echo "$(date -u --rfc-3339=seconds) - setting up static IP assignments"

STATIC_IPS="${SHARED_DIR}"/static-ip-hosts.txt

SUBNETS_CONFIG=/var/run/vault/vsphere-config/subnets.json

# ** NOTE: The first two addresses are not for use. [0] is the network, [1] is the gateway


echo "$(date -u --rfc-3339=seconds) - ${vlanid} ${primaryrouterhostname} "


if ! jq -e --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH] | has($VLANID)' "${SUBNETS_CONFIG}"; then
  echo "VLAN ID: ${vlanid} does not exist on ${primaryrouterhostname} in subnets.json file. This exists in vault - selfservice/vsphere-vmc/config"
  exit 1
fi




dns_server=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].dnsServer' "${SUBNETS_CONFIG}")
gateway=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].gateway' "${SUBNETS_CONFIG}")
cidr=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].cidr' "${SUBNETS_CONFIG}")

cat >>"${STATIC_IPS}" <<EOF
    hosts:
EOF

  cat >>"${STATIC_IPS}" <<EOF
    - role: bootstrap
      networkDevice:
        ipAddrs:
        - $(jq -r --argjson N 4 --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}")/$cidr
        gateway: ${gateway}
        nameservers:
        - ${dns_server}
EOF

  for n in {5..7}; do
    cat >>"${STATIC_IPS}" <<EOF
    - role: control-plane
      networkDevice:
        ipAddrs:
        - $(jq -r --argjson N "$n" --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}")/$cidr
        gateway: ${gateway}
        nameservers:
        - ${dns_server}
EOF
  done

  for n in {8..10}; do
    cat >>"${STATIC_IPS}" <<EOF
    - role: compute
      networkDevice:
        ipAddrs:
        - $(jq -r --argjson N "$n" --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}")/$cidr
        gateway: ${gateway}
        nameservers:
        - ${dns_server}
EOF
  done

echo "$(date -u --rfc-3339=seconds) - set up static IP assignments"
cat "${STATIC_IPS}"
