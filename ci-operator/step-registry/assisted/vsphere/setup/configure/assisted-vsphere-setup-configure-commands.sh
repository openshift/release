#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - failed to acquire lease"
  exit 1
fi

SUBNETS_CONFIG=/var/run/vault/vsphere-config/subnets.json
declare vlanid
declare phydc
declare primaryrouterhostname
declare vsphere_portgroup
SECRET_DIR="/var/run/vault/vsphere/"

# notes: jcallen: this should not be here and def should not be statically defined.
cloud_where_run="VMC"

# For leases >= than 88, run on the IBM Cloud
if [ $((${LEASED_RESOURCE//[!0-9]/})) -ge 88 ]; then
  echo Scheduling job on IBM Cloud instance
  cloud_where_run="IBM"
  SECRET_DIR="/var/run/vault/ibmcloud"
else
  echo Scheduling job on AWS VMC Cloud instance
fi

if [[ ${LEASED_RESOURCE} == *"segment"* ]]; then
  # notes: jcallen: to keep backward compatibility with existing vsphere env(s)
  vsphere_portgroup="${LEASED_RESOURCE}"
  vsphere_url="$(cat ${SECRET_DIR}/vsphere_url)"
  vsphere_cluster="$(cat ${SECRET_DIR}/vsphere_cluster)"
  vsphere_datacenter="$(cat ${SECRET_DIR}/vsphere_datacenter)"
  vsphere_datastore="$(cat ${SECRET_DIR}/vsphere_datastore)"
  vsphere_password="$(cat ${SECRET_DIR}/vsphere_password)"
  vsphere_user="$(cat ${SECRET_DIR}/vsphere_username)"
  vsphere_resource_pool="$(cat ${SECRET_DIR}/vsphere_resource_pool)"
  dns_server="$(cat ${SECRET_DIR}/dns_server)"
  vsphere_dev_network="$(cat ${SECRET_DIR}/vsphere_dev_network)"
else
  # notes: jcallen: split the LEASED_RESOURCE e.g. bcr01a.dal10.1153
  # into: primary router hostname, datacenter and vlan id

  router=$(awk -F. '{print $1}' <(echo "${LEASED_RESOURCE}"))
  phydc=$(awk -F. '{print $2}' <(echo "${LEASED_RESOURCE}"))
  vlanid=$(awk -F. '{print $3}' <(echo "${LEASED_RESOURCE}"))
  primaryrouterhostname="${router}.${phydc}"
  # notes: jcallen: all new subnets resides on port groups named: ci-vlan-#### where #### is the vlan id.
  vsphere_portgroup="ci-vlan-${vlanid}"

  if ! jq -e --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH] | has($VLANID)' "${SUBNETS_CONFIG}"; then
    echo "VLAN ID: ${vlanid} does not exist on ${primaryrouterhostname} in subnets.json file. This exists in vault - selfservice/vsphere-vmc/config"
    exit 1
  fi

  vsphere_url=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].virtualcenter' "${SUBNETS_CONFIG}")
  dns_server=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].dnsServer' "${SUBNETS_CONFIG}")
fi

# govc command persists sessions to GOVMOMI_HOME.
# It's possible to disable session persistence but it might be useful
# Providing a writable directory.
mkdir -p ${SHARED_DIR}/govc

echo "$(date -u --rfc-3339=seconds) - Creating govc.sh file..."
cat >>"${SHARED_DIR}/govc.sh" <<EOF
export GOVMOMI_HOME="${SHARED_DIR}/govc"
export GOVC_URL="${vsphere_url}"
export GOVC_USERNAME="${vsphere_user}"
export GOVC_PASSWORD='${vsphere_password}'
export GOVC_INSECURE=1
export GOVC_DATACENTER="${vsphere_datacenter}"
export GOVC_DATASTORE="${vsphere_datastore}"
export GOVC_RESOURCE_POOL="${vsphere_resource_pool}"
EOF

echo "$(date -u --rfc-3339=seconds) - Creating vsphere_context.sh file..."
cat >>"${SHARED_DIR}/vsphere_context.sh" <<EOF
export vsphere_url="${vsphere_url}"
export vsphere_cluster="${vsphere_cluster}"
export vsphere_resource_pool="${vsphere_resource_pool}"
export dns_server="${dns_server}"
export cloud_where_run="${cloud_where_run}"
export vsphere_dev_network="${vsphere_dev_network}"
export vsphere_datacenter="${vsphere_datacenter}"
export vsphere_datastore="${vsphere_datastore}"

export vsphere_portgroup="${vsphere_portgroup}"
export vlanid="${vlanid:-unset}"
export phydc="${phydc:-unset}"
export primaryrouterhostname="${primaryrouterhostname:-unset}"
EOF

if [[ ${LEASED_RESOURCE} == *"segment"* ]]; then

  third_octet=$(grep -oP '[ci|qe\-discon]-segment-\K[[:digit:]]+' <(echo "${LEASED_RESOURCE}"))

  cat >>"${SHARED_DIR}/platform-conf.sh" <<EOF
export API_VIP="192.168.${third_octet}.2"
export INGRESS_VIP="192.168.${third_octet}.3"
EOF
else
  if ! jq -e --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH] | has($VLANID)' "${SUBNETS_CONFIG}"; then
    echo "VLAN ID: ${vlanid} does not exist on ${primaryrouterhostname} in subnets.json file. This exists in vault - selfservice/vsphere-vmc/config"
    exit 1
  fi

  api_vip=$(jq -r --argjson N 2 --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}")
  ingress_vip=$(jq -r --argjson N 3 --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}")

  cat >>"${SHARED_DIR}/platform-conf.sh" <<EOF
export API_VIP="${api_vip}"
export INGRESS_VIP="${ingress_vip}"
EOF
fi

echo "$(date -u --rfc-3339=seconds) - Creating platform-conf.sh file..."
cat >>"${SHARED_DIR}/platform-conf.sh" <<EOF
export PLATFORM=vsphere
export VIP_DHCP_ALLOCATION=false
export VSPHERE_PARENT_FOLDER=assisted-test-infra-ci
export VSPHERE_FOLDER="build-${BUILD_ID}"
export VSPHERE_CLUSTER="${vsphere_cluster}"
export VSPHERE_USERNAME="${vsphere_user}"
export VSPHERE_NETWORK="${vsphere_portgroup}"

export VSPHERE_VCENTER="${vsphere_url}"
export VSPHERE_DATACENTER="${vsphere_datacenter}"
export VSPHERE_DATASTORE="${vsphere_datastore}"
export VSPHERE_PASSWORD='${vsphere_password}'
export BASE_DOMAIN="vmc-ci.devcluster.openshift.com"
export CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
EOF
