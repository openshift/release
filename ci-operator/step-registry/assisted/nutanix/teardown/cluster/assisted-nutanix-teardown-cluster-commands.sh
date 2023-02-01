#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ nutanix assisted test-infra teardown cluster command ************"
# TODO: Remove once OpenShift CI will be upgraded to 4.2 (see https://access.redhat.com/articles/4859371)
/usr/local/bin/fix_uid.sh

mkdir -p /home/assisted-test-infra/build/cluster/
scp -F ${SHARED_DIR}/ssh_config -r "root@ci_machine:/home/assisted/build/terraform/*" "/home/assisted-test-infra/build/cluster/nutanix"
cd /home/assisted-test-infra/build/cluster/nutanix/nutanix
terraform apply -destroy -input=false -auto-approve
