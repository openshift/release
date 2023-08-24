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
source "${SHARED_DIR}/vsphere_context.sh"

echo "$(date -u --rfc-3339=seconds) - setting up static IP assignments"

STATIC_IPS="${SHARED_DIR}"/static-ip-hosts.txt

if [[ ${LEASED_RESOURCE} == *"vlan"* ]]; then
  vlanid=$(grep -oP '[ci|qe\-discon]-vlan-\K[[:digit:]]+' <(echo "${LEASED_RESOURCE}"))

  # ** NOTE: The first two addresses are not for use. [0] is the network, [1] is the gateway

  dns_server=$(jq -r --arg VLANID "$vlanid" '.[$VLANID].dnsServer' /var/run/vault/vsphere-config/subnets.json)
  cidr=$(jq -r --arg VLANID "$vlanid" '.[$VLANID].cidr' /var/run/vault/vsphere-config/subnets.json)
  gateway=$(jq -r --arg VLANID "$vlanid" '.[$VLANID].gateway' /var/run/vault/vsphere-config/subnets.json)


cat >> "${STATIC_IPS}" << EOF
    hosts:
EOF

  for n in {4..4}
  do
cat >> "${STATIC_IPS}" << EOF
    - role: bootstrap
      networkDevice:
        ipAddrs:
        - $(jq -r --argjson N $n --arg VLANID "$vlanid" '.[$VLANID].ipAddresses[$N]' /var/run/vault/vsphere-config/subnets.json)/$cidr
        gateway: ${gateway}
        nameservers:
        - ${dns_server}
EOF
  done

  for n in {5..7}
  do
cat >> "${STATIC_IPS}" << EOF
    - role: control-plane
      networkDevice:
        ipAddrs:
        - $(jq -r --argjson N $n --arg VLANID "$vlanid" '.[$VLANID].ipAddresses[$N]' /var/run/vault/vsphere-config/subnets.json)/$cidr
        gateway: ${gateway}
        nameservers:
        - ${dns_server}
EOF
  done


  for n in {8..10}
  do
cat >> "${STATIC_IPS}" << EOF
    - role: compute
      networkDevice:
        ipAddrs:
        - $(jq -r --argjson N $n --arg VLANID "$vlanid" '.[$VLANID].ipAddresses[$N]' /var/run/vault/vsphere-config/subnets.json)/$cidr
        gateway: ${gateway}
        nameservers:
        - ${dns_server}
EOF
  done

else
  third_octet=$(grep -oP '[ci|qe\-discon]-segment-\K[[:digit:]]+' <(echo "${LEASED_RESOURCE}"))

cat >> "${STATIC_IPS}" << EOF
    hosts:
    - role: bootstrap
      networkDevice:
        ipAddrs:
        - 192.168.${third_octet}.5/24
        gateway: 192.168.${third_octet}.1
        nameservers:
        - ${dns_server}
    - role: control-plane
      networkDevice:
        ipAddrs:
        - 192.168.${third_octet}.6/24
        gateway: 192.168.${third_octet}.1
        nameservers:
        - ${dns_server}
    - role: control-plane
      networkDevice:
        ipAddrs:
        - 192.168.${third_octet}.7/24
        gateway: 192.168.${third_octet}.1
        nameservers:
        - ${dns_server}
    - role: control-plane
      networkDevice:
        ipAddrs:
        - 192.168.${third_octet}.8/24
        gateway: 192.168.${third_octet}.1
        nameservers:
        - ${dns_server}
    - role: compute
      networkDevice:
        ipAddrs:
        - 192.168.${third_octet}.9/24
        gateway: 192.168.${third_octet}.1
        nameservers:
        - ${dns_server}
    - role: compute
      networkDevice:
        ipAddrs:
        - 192.168.${third_octet}.10/24
        gateway: 192.168.${third_octet}.1
        nameservers:
        - ${dns_server}
    - role: compute
      networkDevice:
        ipAddrs:
        - 192.168.${third_octet}.11/24
        gateway: 192.168.${third_octet}.1
        nameservers:
        - ${dns_server}
EOF

fi

echo "$(date -u --rfc-3339=seconds) - set up static IP assignments"
cat "${STATIC_IPS}"
