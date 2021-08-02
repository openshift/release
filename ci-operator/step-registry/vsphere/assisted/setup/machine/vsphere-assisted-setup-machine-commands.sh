#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ vsphere assisted test-infra machine setup command ************"

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

echo "Installing vsphere cli(govc)"
go get -u github.com/vmware/govmomi/govc

# Define vsphere params
tfvars_path=/var/run/vault/vsphere/secret.auto.tfvars
vsphere_user=$(grep -oP 'vsphere_user\s*=\s*"\K[^"]+' ${tfvars_path})
vsphere_password=$(grep -oP 'vsphere_password\s*=\s*"\K[^"]+' ${tfvars_path})
vsphere_vcenter=vcenter.sddc-44-236-21-251.vmwarevmc.com
vsphere_datacenter=SDDC-Datacenter
vsphere_datastore=WorkloadDatastore
vsphere_network=${LEASED_RESOURCE}

# Define govc connectivity params file
cat >> "${SHARED_DIR}/govc.sh" << EOF
export GOVC_URL="${vsphere_vcenter}"
export GOVC_USERNAME="${vsphere_user}"
export GOVC_PASSWORD="${vsphere_password}"
export GOVC_INSECURE=1
export GOVC_DATACENTER="${vsphere_datacenter}"
export GOVC_DATASTORE="${vsphere_datastore}"
EOF

source ${SHARED_DIR}/govc.sh



sleep 1h