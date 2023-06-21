#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - failed to acquire lease"
    exit 1
fi

vsphere_datacenter="SDDC-Datacenter"
vsphere_datastore="WorkloadDatastore"
vsphere_cluster="Cluster-1"
cloud_where_run="VMC"
dns_server="10.0.0.2"
vsphere_resource_pool=""
vsphere_url="vcenter.sddc-44-236-21-251.vmwarevmc.com"

VCENTER_AUTH_PATH=/var/run/vault/vsphere/secrets.sh

LEASE_NUMBER=$((${LEASED_RESOURCE//[!0-9]/}))
# For leases >= than 88, run on the IBM Cloud
if [ ${LEASE_NUMBER} -ge 88 ] && [ ${LEASE_NUMBER} -lt 200 ]; then
  echo Scheduling job on IBM Cloud instance
  VCENTER_AUTH_PATH=/var/run/vault/ibmcloud/secrets.sh
  vsphere_url="ibmvcenter.vmc-ci.devcluster.openshift.com"
  vsphere_datacenter="IBMCloud"
  cloud_where_run="IBM"
  dns_server="10.38.76.172"
  vsphere_resource_pool="/IBMCloud/host/vcs-ci-workload/Resources"
  vsphere_cluster="vcs-ci-workload"
  vsphere_datastore="vsanDatastore"
fi
# For leases >= than 151 and < 160, pull from alternate DNS which has context
# relevant to NSX-T segments.
if [ ${LEASE_NUMBER} -ge 151 ] && [ ${LEASE_NUMBER} -lt 160 ]; then
  dns_server="192.168.133.73"
fi

# For leases >= 200, run on the IBM Cloud vSphere 8 env
if [ ${LEASE_NUMBER} -ge 200 ]; then
  echo Scheduling job on IBM Cloud instance
  VCENTER_AUTH_PATH=/var/run/vault/vsphere8-secrets/secrets.sh
  vsphere_url="vcenter.ibmc.devcluster.openshift.com"
  vsphere_datacenter="IBMCdatacenter"
  cloud_where_run="IBM8"
  dns_server="192.168.${LEASE_NUMBER}.1"
  vsphere_resource_pool="/IBMCdatacenter/host/IBMCcluster/Resources/ipi-ci-clusters"
  vsphere_cluster="IBMCcluster"
  vsphere_datastore="vsanDatastore"
fi

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


# The release controller starts four CI jobs concurrently: UPI, IPI, parallel and serial
# We are currently having high CPU ready time in the vSphere CI cluster and this
# does not help the situation. For periodics create a slight random delay
# before continuing job progression.

if [[ "${JOB_TYPE}" = "periodic" ]]; then
    sleep "$(( RANDOM % 240 + 60 ))"s
fi
