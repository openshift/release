#!/bin/bash

grab_vip_seg() {
  third_octet=$1
  fourth_octet=$2
  echo "192.168.${third_octet}.${fourth_octet}" >>"${SHARED_DIR}"/vips.txt
}

grab_vip() {
  fourth_octet=$1
  jq -r --argjson N "$fourth_octet" --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}" >>"${SHARED_DIR}"/vips.txt
}

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

echo "Reserved the following IP addresses..."

SUBNETS_CONFIG=/var/run/vault/vsphere-config/subnets.json
declare vlanid
declare primaryrouterhostname
declare vsphere_portgroup
source "${SHARED_DIR}/vsphere_context.sh"

num_vips=$((2 + 2*${#VSPHERE_ADDITIONAL_BASEDOMAINS[@]}))

if [[ ${vsphere_portgroup} == *"segment"* ]]; then
  third_octet=$(grep -oP '[ci|qe\-discon]-segment-\K[[:digit:]]+' <(echo "${LEASED_RESOURCE}"))

  # IBMC devqe do not support using 192.168.*.1 or 2 as vips
  echo "192.168.${third_octet}.0/25" >>"${SHARED_DIR}"/machinecidr.txt

  # IBMC devqe do not support using 192.168.*.1 or 2 as vips. Start at .3 and .4
    for ((i=1; i<=num_vips; i++)); do
      grab_vip_seg "${third_octet}" $((i+2))
    done
else
  if ! jq -e --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH] | has($VLANID)' "${SUBNETS_CONFIG}"; then
    echo "VLAN ID: ${vlanid} does not exist on ${primaryrouterhostname} in subnets.json file. This exists in vault - selfservice/vsphere-vmc/config"
    exit 1
  fi
  jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].machineNetworkCidr' "${SUBNETS_CONFIG}" >>"${SHARED_DIR}"/machinecidr.txt

  for ((i=1; i<=num_vips; i++)); do
    grab_vip $((i+1))
  done
fi

cat "${SHARED_DIR}"/vips.txt
