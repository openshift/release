#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ nutanix assisted test-infra teardown command ************"

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

if [[ ! -r "${SHARED_DIR}/terraform.tgz" ]]; then
    echo "No Terraform file exists - probably no Nutanix machine was created - skipping teardown"
    exit 0
fi

mkdir -p /home/assisted-test-infra/build/terraform
cp ${SHARED_DIR}/terraform.tgz /tmp/
cd /home/assisted-test-infra/build/terraform
tar -xvf /tmp/terraform.tgz -C /

# shellcheck disable=SC2034
source $SHARED_DIR/nutanix_context.sh
# shellcheck source=/dev/random
source $SHARED_DIR/platform-conf.sh
terraform init -input=false
terraform destroy -var-file=nutanix-params.hcl -input=false -auto-approve
