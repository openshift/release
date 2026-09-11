#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ nutanix assisted test-infra teardown cluster command ************"
# TODO: Remove once OpenShift CI will be upgraded to 4.2 (see https://access.redhat.com/articles/4859371)
/usr/local/bin/fix_uid.sh
ssh -F ${SHARED_DIR}/ssh_config "root@ci_machine" bash - << EOF |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
set -xeuo pipefail
source /root/config.sh
cd /home/assisted
# Connect to minikube instead of spoke cluster
unset KUBECONFIG
make destroy_nutanix
EOF
