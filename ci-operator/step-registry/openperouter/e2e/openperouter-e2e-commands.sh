#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ openperouter deploy-verify test ************"

# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

echo "### Set up extra networks, create OpenPERouter CR, and verify deployment"
ssh "${SSHOPTS[@]}" "root@${IP}" bash /dev/stdin << 'RUNTESTS'
set -xeo pipefail
cd /root/dev-scripts
source common.sh
source ocp_install_env.sh
set -u
export KUBECONFIG="/root/dev-scripts/ocp/${CLUSTER_NAME}/auth/kubeconfig"

export CONFIG=/root/dev-scripts/config_root.sh

echo "Kernel release: $(uname -r)"
echo "Kernel version: $(uname -v)"

unset DOCKER_HOST

bash /root/openperouter/openshift/e2e/deploy.sh </dev/null
bash /root/openperouter/openshift/e2e/run_tests.sh </dev/null

RUNTESTS
