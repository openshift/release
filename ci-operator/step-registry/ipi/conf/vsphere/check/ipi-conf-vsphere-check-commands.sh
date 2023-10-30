#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - failed to acquire lease"
  exit 1
fi

declare vsphere_datacenter
declare vsphere_datastore
declare vsphere_cluster
declare cloud_where_run
declare dns_server
declare vsphere_resource_pool
declare vsphere_url
declare VCENTER_AUTH_PATH
declare vlanid
declare router
declare phydc
declare primaryrouterhostname
declare vsphere_portgroup
declare -a portgroup_list

SUBNETS_CONFIG=/var/run/vault/vsphere-config/subnets.json
declare vsphere_url

if [[ ${LEASED_RESOURCE} == *"segment"* ]]; then
  # notes: jcallen: to keep backward compatiability with existing vsphere env(s)
  vsphere_portgroup="${LEASED_RESOURCE}"
else
  # notes: jcallen: split the LEASED_RESOURCE e.g. bcr01a.dal10.1153
  # into: primary router hostname, datacenter and vlan id

  router=$(awk -F. '{print $1}' <(echo "${LEASED_RESOURCE}"))
  phydc=$(awk -F. '{print $2}' <(echo "${LEASED_RESOURCE}"))
  vlanid=$(awk -F. '{print $3}' <(echo "${LEASED_RESOURCE}"))
  primaryrouterhostname="${router}.${phydc}"

  # notes: jcallen: all new subnets resides on port groups named: ci-vlan-#### where #### is the vlan id.
  vsphere_portgroup="ci-vlan-${vlanid}"
  portgroup_list+=("${vsphere_portgroup}")
  if ! jq -e --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH] | has($VLANID)' "${SUBNETS_CONFIG}"; then
    echo "VLAN ID: ${vlanid} does not exist on ${primaryrouterhostname} in subnets.json file. This exists in vault - selfservice/vsphere-vmc/config"
    exit 1
  fi

  vsphere_url=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].virtualcenter' "${SUBNETS_CONFIG}")

  dns_server=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].dnsServer' "${SUBNETS_CONFIG}")

fi

#to support vsphere-ipi-zones-multisubnets-external-lb, which need 3 different subnets, add these var to specify the multisubnets portgroups.
if [[ -n "${VSPHERE_MULTIZONE_LEASED_RESOURCE:-}" ]]; then
    i=0
    for multizone_leased_resource in ${VSPHERE_MULTIZONE_LEASED_RESOURCE}; do    
	 multizone_vlanid=$(awk -F. '{print $3}' <(echo "${multizone_leased_resource}"))
	 multizone_portgroup="ci-vlan-${multizone_vlanid}"
	 i=$((i + 1))
	 portgroup_list+=("${multizone_portgroup}")
	 cat >>"${SHARED_DIR}/vsphere_context.sh" <<EOF
export multizone_portgroup_${i}="${multizone_portgroup}"
EOF
    done
fi    
source /var/run/vault/vsphere-config/load-vsphere-env-config.sh

declare vcenter_usernames
declare vcenter_passwords
# shellcheck source=/dev/null
source "${VCENTER_AUTH_PATH}"

account_loc=$(($RANDOM % 4))
vsphere_user="${vcenter_usernames[$account_loc]}"
vsphere_password="${vcenter_passwords[$account_loc]}"

echo "$(date -u --rfc-3339=seconds) - Creating govc.sh file..."
cat >>"${SHARED_DIR}/govc.sh" <<EOF
export GOVC_URL="${vsphere_url}"
export GOVC_USERNAME="${vsphere_user}"
export GOVC_PASSWORD="${vsphere_password}"
export GOVC_INSECURE=1
export GOVC_DATACENTER="${vsphere_datacenter}"
export GOVC_DATASTORE="${vsphere_datastore}"
export GOVC_RESOURCE_POOL=${vsphere_resource_pool}
EOF

echo "$(date -u --rfc-3339=seconds) - Creating vsphere_context.sh file..."
cat >>"${SHARED_DIR}/vsphere_context.sh" <<EOF
export vsphere_url="${vsphere_url}"
export vsphere_cluster="${vsphere_cluster}"
export vsphere_resource_pool="${vsphere_resource_pool}"
export dns_server="${dns_server}"
export cloud_where_run="${cloud_where_run}"
export vsphere_datacenter="${vsphere_datacenter}"
export vsphere_datastore="${vsphere_datastore}"
export vsphere_portgroup="${vsphere_portgroup}"
export vlanid="${vlanid:-unset}"
export phydc="${phydc:-unset}"
export primaryrouterhostname="${primaryrouterhostname:-unset}"
EOF

if [[ -n "${VSPHERE_CONNECTED_LEASED_RESOURCE:-}" ]]; then
  vlanid_2=$(awk -F. '{print $3}' <(echo "${VSPHERE_CONNECTED_LEASED_RESOURCE}"))
  vsphere_connected_portgroup="ci-vlan-${vlanid_2}"
  cat >>"${SHARED_DIR}/vsphere_context.sh" <<EOF
export vsphere_connected_portgroup="${vsphere_connected_portgroup}"
EOF
  portgroup_list+=("${vsphere_connected_portgroup}")
fi

# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

DATACENTERS=("$GOVC_DATACENTER")
# If testing a zonal install, there are multiple datacenters that will need to be cleaned up
# vlanid between 1287 and 1302 will use profile:vsphere-multizone-2
if [ ${vlanid} -ge 1287 ] && [ ${vlanid} -le 1302 ]; then
  DATACENTERS=(
    "IBMCloud"
    "datacenter-2"
  )
fi

# 1. Get the OpaqueNetwork (NSX-T port group) which is listed in LEASED_RESOURCE.
# 2. Select the virtual machines attached to network
# 3. list the path to the virtual machine via the managed object reference
# 4. skip the templates with ova
# 5. Power off and delete the virtual machine

# disable error checking in this section
# randomly delete may fail, this shouldn't cause an immediate issue
# but should eventually be cleaned up.
set +e
for i in "${!DATACENTERS[@]}"; do
  echo "$(date -u --rfc-3339=seconds) - Find virtual machines attached to ${vsphere_portgroup} in DC ${DATACENTERS[$i]} and destroy"
  DATACENTER=$(echo -n ${DATACENTERS[$i]} | tr -d '\n')
  for portgroup in "${portgroup_list[@]}"; do
     govc ls -json "/${DATACENTER}/network/${portgroup}" |
      jq '.elements[]?.Object.Vm[]?.Value' |
      xargs -I {} --no-run-if-empty govc ls -json -L VirtualMachine:{} |
      jq '.elements[].Path | select((contains("ova") or test("\\bci-segment-[0-9]?[0-9]?[0-9]-bastion\\b")) | not)' |
      xargs -I {} --no-run-if-empty govc vm.destroy {}
  done
done
set -e
