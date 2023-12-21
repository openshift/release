#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

declare primaryrouterhostname
declare vlanid
declare vsphere_cluster
declare vsphere_datacenter
declare vsphere_datastore
declare vsphere_portgroup
declare vsphere_url

# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"
# shellcheck source=/dev/null
source "${SHARED_DIR}/vsphere_context.sh"

SUBNETS_CONFIG=/var/run/vault/vsphere-config/subnets.json

if [[ ${LEASED_RESOURCE} == *"segment"* ]]; then

  third_octet=$(grep -oP '[ci|qe\-discon]-segment-\K[[:digit:]]+' <(echo "${LEASED_RESOURCE}"))

  cat >>"${SHARED_DIR}/platform-conf.sh" <<EOF
export API_VIPS="[{\"ip\": \"192.168.${third_octet}.2\"}]"
export INGRESS_VIPS="[{\"ip\": \"192.168.${third_octet}.3\"}]"
EOF
else
  if ! jq -e --arg PRH "${primaryrouterhostname}" --arg VLANID "${vlanid}" '.[$PRH] | has($VLANID)' "${SUBNETS_CONFIG}"; then
    echo "VLAN ID: ${vlanid} does not exist on ${primaryrouterhostname} in subnets.json file. This exists in vault - selfservice/vsphere-vmc/config"
    exit 1
  fi

  api_vip=$(jq -r --argjson N 2 --arg PRH "${primaryrouterhostname}" --arg VLANID "${vlanid}" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}")
  ingress_vip=$(jq -r --argjson N 3 --arg PRH "${primaryrouterhostname}" --arg VLANID "${vlanid}" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}")

  cat >>"${SHARED_DIR}/platform-conf.sh" <<EOF
export API_VIPS="[{\"ip\": \"${api_vip}\"}]"
export INGRESS_VIPS="[{\"ip\": \"${ingress_vip}\"}]"
EOF
fi

echo "$(date -u --rfc-3339=seconds) - Creating platform-conf.sh file..."
cat >>"${SHARED_DIR}/platform-conf.sh" <<EOF
export PLATFORM=vsphere
# disable capture logs in pytest to prevent leaking vsphere password
export PYTEST_FLAGS="--error-for-skips --show-capture=no"

export VIP_DHCP_ALLOCATION=false
export VSPHERE_PARENT_FOLDER=assisted-test-infra-ci
export VSPHERE_FOLDER="build-${BUILD_ID}"
export VSPHERE_CLUSTER="${vsphere_cluster}"
export VSPHERE_USERNAME="${GOVC_USERNAME}"
export VSPHERE_NETWORK="${vsphere_portgroup}"

export VSPHERE_VCENTER="${vsphere_url}"
export VSPHERE_DATACENTER="${vsphere_datacenter}"
export VSPHERE_DATASTORE="${vsphere_datastore}"
export VSPHERE_PASSWORD='${GOVC_PASSWORD}'
export BASE_DOMAIN="vmc-ci.devcluster.openshift.com"
export CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
EOF
