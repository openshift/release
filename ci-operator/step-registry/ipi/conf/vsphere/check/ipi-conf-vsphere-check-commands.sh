#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - failed to acquire lease"
    exit 1
fi

LEASE_NUMBER=$((${LEASED_RESOURCE//[!0-9]/}))

declare vsphere_datacenter
declare vsphere_datastore
declare vsphere_cluster
declare cloud_where_run
declare dns_server
declare vsphere_resource_pool
declare vsphere_url
declare LEASE_NUMBER
declare VCENTER_AUTH_PATH

# For leases >= 221, run on the IBM Cloud vSphere env
if [ ${LEASE_NUMBER} -ge 221 ]; then
  echo Scheduling job on IBM Cloud instance
  VCENTER_AUTH_PATH=/var/run/vault/devqe-secrets/secrets.sh
  vsphere_url="vcenter.devqe.ibmc.devcluster.openshift.com"
  vsphere_datacenter="DEVQEdatacenter"
  cloud_where_run="IBMC-DEVQE"
  dns_server="192.168.${LEASE_NUMBER}.1"
  vsphere_resource_pool="/DEVQEdatacenter/host/DEVQEcluster/Resources/ipi-ci-clusters"
  vsphere_cluster="DEVQEcluster"
  vsphere_datastore="vsanDatastore"
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
cat >> "${SHARED_DIR}/govc.sh" << EOF
export GOVC_URL="${vsphere_url}"
export GOVC_USERNAME="${vsphere_user}"
export GOVC_PASSWORD="${vsphere_password}"
export GOVC_INSECURE=1
export GOVC_DATACENTER="${vsphere_datacenter}"
export GOVC_DATASTORE="${vsphere_datastore}"
export GOVC_RESOURCE_POOL=${vsphere_resource_pool}
EOF

echo "$(date -u --rfc-3339=seconds) - Creating vsphere_context.sh file..."
cat >> "${SHARED_DIR}/vsphere_context.sh" << EOF
export vsphere_url="${vsphere_url}"
export vsphere_cluster="${vsphere_cluster}"
export vsphere_resource_pool="${vsphere_resource_pool}"
export dns_server="${dns_server}"
export cloud_where_run="${cloud_where_run}"
export vsphere_datacenter="${vsphere_datacenter}"
export vsphere_datastore="${vsphere_datastore}"
EOF

# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

DATACENTERS=("$GOVC_DATACENTER")
# If testing a zonal install, there are multiple datacenters that will need to be cleaned up
if [ ${LEASE_NUMBER} -ge 151 ] && [ ${LEASE_NUMBER} -le 157 ]; then
  DATACENTERS=(
    "IBMCloud"
    "datacenter-2"
  )
fi

sleep 3600

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
  echo "$(date -u --rfc-3339=seconds) - Find virtual machines attached to ${LEASED_RESOURCE} in DC ${DATACENTERS[$i]} and destroy"
  DATACENTER=$(echo -n ${DATACENTERS[$i]} |  tr -d '\n')
  govc ls -json "/${DATACENTER}/network/${LEASED_RESOURCE}" |\
      jq '.elements[]?.Object.Vm[]?.Value' |\
      xargs -I {} --no-run-if-empty govc ls -json -L VirtualMachine:{} |\
      jq '.elements[].Path | select((contains("ova") or test("\\bci-segment-[0-9]?[0-9]?[0-9]-bastion\\b")) | not)' |\
      xargs -I {} --no-run-if-empty govc vm.destroy {}
done
set -e
