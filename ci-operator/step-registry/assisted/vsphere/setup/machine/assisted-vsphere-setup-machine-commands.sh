#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ vsphere assisted test-infra setup machine command ************"

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

export vsphere_cluster=""
source $SHARED_DIR/vsphere_context.sh

# Ensures that the vsphere template exists.
source ${SHARED_DIR}/govc.sh
mkdir -p build/govc
export GOVMOMI_HOME=/home/assisted-test-infra/build/govc/
govc object.collect /${GOVC_DATACENTER}/vm/assisted-test-infra-ci/assisted-test-infra-machine-template || { echo 'Assisted service ci template does not exist' ; exit 1; }

# Cloning the template into a new CI VM.
mkdir -p /home/assisted-test-infra/build/terraform
cp -r terraform_files/vsphere-ci-machine/* /home/assisted-test-infra/build/terraform/
cd /home/assisted-test-infra/build/terraform

# Create variables file
cat >> vsphere-params.hcl << EOF
vsphere_vcenter = "${GOVC_URL}"
vsphere_username = "${GOVC_USERNAME}"
vsphere_password = "${GOVC_PASSWORD}"
vsphere_datacenter = "${GOVC_DATACENTER}"
vsphere_datastore = "${GOVC_DATASTORE}"
vsphere_cluster = "${vsphere_cluster}"
vsphere_network = "${LEASED_RESOURCE}"
template_name = "assisted-test-infra-machine-template"
build_id = "${BUILD_ID}"
EOF

terraform init .
terraform apply -var-file=vsphere-params.hcl -auto-approve
cd ..
tar -cvzf terraform.tgz --exclude=".terraform" /home/assisted-test-infra/build/terraform
cp terraform.tgz ${SHARED_DIR}