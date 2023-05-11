#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

echo "$(date -u --rfc-3339=seconds) - setting up static IP assignments"

STATIC_IPS="${SHARED_DIR}"/static-ip-hosts.txt

third_octet=$(grep -oP '[ci|qe\-discon]-segment-\K[[:digit:]]+' <(echo "${LEASED_RESOURCE}"))

cat >> "${STATIC_IPS}" << EOF
    hosts:
    - role: bootstrap
      networkDevice:
        ipAddrs:
        - 192.168.${third_octet}.4/24
        gateway4: 192.168.${third_octet}.1
        nameservers:
        - 8.8.8.8
    - role: control-plane
      networkDevice:
        ipAddrs:
        - 192.168.${third_octet}.5/24
        gateway4: 192.168.${third_octet}.1
        nameservers:
        - 8.8.8.8
    - role: control-plane
      networkDevice:
        ipAddrs:
        - 192.168.${third_octet}.6/24
        gateway4: 192.168.${third_octet}.1
        nameservers:
        - 8.8.8.8
    - role: control-plane
      networkDevice:
        ipAddrs:
        - 192.168.${third_octet}.7/24
        gateway4: 192.168.${third_octet}.1
        nameservers:
        - 8.8.8.8
    - role: compute
      networkDevice:
        ipAddrs:
        - 192.168.${third_octet}.8/24
        gateway4: 192.168.${third_octet}.1
        nameservers:
        - 8.8.8.8
    - role: compute
      networkDevice:
        ipAddrs:
        - 192.168.${third_octet}.9/24
        gateway4: 192.168.${third_octet}.1
        nameservers:
        - 8.8.8.8
    - role: compute
      networkDevice:
        ipAddrs:
        - 192.168.${third_octet}.10/24
        gateway4: 192.168.${third_octet}.1
        nameservers:
        - 8.8.8.8"
EOF

echo "$(date -u --rfc-3339=seconds) - set up static IP assignments"
cat "${STATIC_IPS}"
