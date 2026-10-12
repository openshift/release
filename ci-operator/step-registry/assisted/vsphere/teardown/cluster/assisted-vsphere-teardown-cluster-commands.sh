#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ vsphere assisted test-infra teardown cluster command ************"
/usr/local/bin/fix_uid.sh

ssh -F ${SHARED_DIR}/ssh_config "root@ci_machine" bash - << EOF |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
set -euo pipefail
source /root/config.sh

set -x
cd /home/assisted
# Use minikube instead of spoke cluster
unset KUBECONFIG
make destroy_vsphere
EOF
