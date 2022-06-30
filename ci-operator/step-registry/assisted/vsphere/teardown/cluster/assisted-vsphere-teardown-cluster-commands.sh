#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ vsphere assisted test-infra teardown cluster command ************"
mkdir -p /home/assisted-test-infra/build/cluster/
scp -F ${SHARED_DIR}/ssh_config -r "root@ci_machine:/home/assisted/build/terraform/*" "/home/assisted-test-infra/build/cluster/"
for DIR in /home/assisted-test-infra/build/cluster/*; do (cd "$DIR" &&  terraform apply -destroy -input=false -auto-approve); done

