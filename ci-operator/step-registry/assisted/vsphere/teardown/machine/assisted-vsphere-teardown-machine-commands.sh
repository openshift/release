#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ vsphere assisted test-infra teardown machine command ************"

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

mkdir -p /home/assisted-test-infra/build/terraform
cp ${SHARED_DIR}/terraform.tgz /home/assisted-test-infra/build/terraform
cd /home/assisted-test-infra/build/terraform
tar -xvf terraform.tgz
terraform init
terraform destroy -force