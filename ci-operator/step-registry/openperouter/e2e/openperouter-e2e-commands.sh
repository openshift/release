#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ openperouter deploy-verify test ************"

# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

echo "### Cloning OpenPERouter E2E source to remote host"
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "${OPENPEROUTER_REPO}" "${OPENPEROUTER_BRANCH}" << 'EOFSOURCE'
set -euo pipefail
repository="$1"
branch="$2"

rm -rf /root/openperouter
git clone --depth 1 --branch "${branch}" "${repository}" /root/openperouter
EOFSOURCE

echo "### Set up extra networks, create OpenPERouter CR, and verify deployment"
sleep 5h
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

bash /root/openperouter/openshift/e2e/deploy.sh </dev/null
bash /root/openperouter/openshift/e2e/run_tests.sh </dev/null

RUNTESTS
