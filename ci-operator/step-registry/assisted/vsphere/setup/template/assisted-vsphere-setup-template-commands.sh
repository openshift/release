#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ vsphere assisted test-infra setup template command ************"

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

source ${SHARED_DIR}/govc.sh
echo "Data center is ${GOVC_DATACENTER}"
if govc object.collect /${GOVC_DATACENTER}/vm/assisted-test-infra-ci/assisted-test-infra-machine-template; then
    printf 'Assisted service ci template already exist - skipping \n'
    exit 0
fi

printf 'Assisted service ci template does not exist - creating using packer\n'

export vsphere_cluster=""
export vsphere_dev_network=""
source $SHARED_DIR/vsphere_context.sh
SSH_PUBLIC_KEY="$(cat /var/run/vault/sshkeys/public_key)"

mkdir -p build/packer
cp -r packer_files/vsphere_centos_template/* build/packer/
cd build/packer/

# Create packer variables file
cat >> vsphere-params.hcl << EOF
vsphere_vcenter = "${GOVC_URL}"
vsphere_username = "${GOVC_USERNAME}"
vsphere_password = "${GOVC_PASSWORD}"
vsphere_datacenter = "${GOVC_DATACENTER}"
vsphere_datastore = "${GOVC_DATASTORE}"
vsphere_cluster = "${vsphere_cluster}"
vsphere_network = "${vsphere_dev_network}"
vsphere_folder = "assisted-test-infra-ci"
vm_name = "assisted-test-infra-machine-template"
ssh_public_key = "${SSH_PUBLIC_KEY}"
ssh_private_key_file = "/var/run/vault/sshkeys/private_key"
EOF

export PACKER_CONFIG_DIR=/home/assisted-test-infra/build/packer/config
export PACKER_CACHE_DIR=$PACKER_CONFIG_DIR/cache
packer.io init .
packer.io build -on-error=cleanup -var-file=vsphere-params.hcl .