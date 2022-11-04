#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ nutanix assisted test-infra teardown cluster command ************"

mkdir -p /home/assisted-test-infra/build/cluster/
scp -F ${SHARED_DIR}/ssh_config -r "root@ci_machine:/home/assisted/build/terraform/*" "/home/assisted-test-infra/build/cluster/nutanix"
cd /home/assisted-test-infra/build/cluster/nutanix/nutanix
terraform apply -destroy -input=false -auto-approve
