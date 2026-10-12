#!/bin/bash

set -euo pipefail

if [[ "${NUTANIX_DHCP_CONFIRMED:-false}" != "true" ]]; then
  echo "Set NUTANIX_DHCP_CONFIRMED=true only after validating DHCP on the Nutanix lease subnet."
  exit 1
fi

if [[ ! "${NUTANIX_INGRESS_VIP:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || ! awk -F. '$1 < 256 && $2 < 256 && $3 < 256 && $4 < 256' <<<"${NUTANIX_INGRESS_VIP}"; then
  echo "NUTANIX_INGRESS_VIP must be a reserved IPv4 address reachable from Nutanix workers."
  exit 1
fi

if [[ "${IP_STACK:-v4}" != "v4" ]]; then
  echo "The Nutanix Agent worker flow currently supports IPv4 only."
  exit 1
fi

echo "Nutanix DHCP and ingress network prerequisites are confirmed."
