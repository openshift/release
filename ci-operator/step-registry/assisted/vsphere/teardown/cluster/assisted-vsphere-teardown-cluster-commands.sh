#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ vsphere assisted test-infra teardown cluster command ************"
/usr/local/bin/fix_uid.sh

ssh -F ${SHARED_DIR}/ssh_config "root@ci_machine" bash - << EOF |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
set -xeuo pipefail
source /root/config.sh
cd /home/assisted
# Use minikube kubeconfig instead of spoke cluster unless kube API is used
if [[ -z "\${KUBE_API+z}" ]]; then
  unset KUBECONFIG
  make destroy_vsphere
else
  for DIR in /home/assisted-test-infra/build/cluster/*; do (skipper run "cd \$DIR; terraform apply -destroy -input=false -auto-approve"); done
fi
EOF
