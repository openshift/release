#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ vsphere assisted test-infra teardown cluster command ************"
/usr/local/bin/fix_uid.sh
mkdir -p /home/assisted-test-infra/build/cluster/
scp -F ${SHARED_DIR}/ssh_config -r "root@ci_machine:/home/assisted/build/terraform/*" "/home/assisted-test-infra/build/cluster/vsphere"
cd /home/assisted-test-infra/build/cluster/vsphere/vsphere
terraform apply -destroy -input=false -auto-approve
