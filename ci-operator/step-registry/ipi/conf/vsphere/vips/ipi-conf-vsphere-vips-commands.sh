#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

echo "Reserved the following IP addresses..."

if [[ ${LEASED_RESOURCE} == *"vlan"* ]]; then
  vlanid=$(grep -oP '[ci|qe\-discon]-vlan-\K[[:digit:]]+' <(echo "${LEASED_RESOURCE}"))
  jq -r --argjson N 2 --arg VLANID "$vlanid" '.[$VLANID].ipAddresses[$N]' /var/run/vault/vsphere-config/subnets.json >> "${SHARED_DIR}"/vips.txt
  jq -r --argjson N 3 --arg VLANID "$vlanid" '.[$VLANID].ipAddresses[$N]' /var/run/vault/vsphere-config/subnets.json >> "${SHARED_DIR}"/vips.txt
  jq -r --arg VLANID "$vlanid" '.[$VLANID].machineNetworkCidr' /var/run/vault/vsphere-config/subnets.json >>  "${SHARED_DIR}"/machinecidr.txt
else
  third_octet=$(grep -oP '[ci|qe\-discon]-segment-\K[[:digit:]]+' <(echo "${LEASED_RESOURCE}"))

# IBMC devqe do not support using 192.168.*.1 or 2 as vips
  echo "192.168.${third_octet}.3" >> "${SHARED_DIR}"/vips.txt
  echo "192.168.${third_octet}.4" >> "${SHARED_DIR}"/vips.txt
  echo "192.168.${third_octet}.0/25" >> "${SHARED_DIR}"/machinecidr.txt
fi

cat "${SHARED_DIR}"/vips.txt
