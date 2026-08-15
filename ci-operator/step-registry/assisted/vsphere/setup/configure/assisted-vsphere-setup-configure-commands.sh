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

unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS

SUBNETS_CONFIG="${SHARED_DIR}/subnets.json"


if ! jq -e --arg PRH "${primaryrouterhostname}" --arg VLANID "${vlanid}" '.[$PRH] | has($VLANID)' "${SUBNETS_CONFIG}"; then
  echo "VLAN ID: ${vlanid} does not exist on ${primaryrouterhostname} in subnets.json file. This exists in vault - selfservice/vsphere-vmc/config"
  exit 1
fi

api_vip=$(jq -r --argjson N 2 --arg PRH "${primaryrouterhostname}" --arg VLANID "${vlanid}" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}")
ingress_vip=$(jq -r --argjson N 3 --arg PRH "${primaryrouterhostname}" --arg VLANID "${vlanid}" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}")

# Set the VIPs to be the load balancer IP in case of user-managed LB.
load_balancer_type=$(echo "$ASSISTED_CONFIG" | awk -F'=' '/^LOAD_BALANCER_TYPE=/{print $2}')
if [ -n "$load_balancer_type" ]; then
    echo "LOAD_BALANCER_TYPE: $load_balancer_type"
else
    echo "LOAD_BALANCER_TYPE not found"
fi

if [ "${load_balancer_type:=cluster-managed}" = "user-managed" ]; then
  mapfile -t vips <"${SHARED_DIR}"/vips.txt
  api_vip=${vips[0]}
  ingress_vip=${vips[1]}
  load_balancer_cidr=$(<"${SHARED_DIR}"/machinecidr.txt)
fi

echo "API VIP is ${api_vip}"
echo "INGRESS VIP is ${ingress_vip}"

if [ "${load_balancer_cidr:-}" != "" ]; then
  echo "Load balancer CIDR is ${load_balancer_cidr}"
fi

  cat >>"${SHARED_DIR}/platform-conf.sh" <<EOF
export API_VIPS="[{\"ip\": \"${api_vip}\"}]"
export INGRESS_VIPS="[{\"ip\": \"${ingress_vip}\"}]"
export LOAD_BALANCER_CIDR="${load_balancer_cidr:-}"
EOF

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
