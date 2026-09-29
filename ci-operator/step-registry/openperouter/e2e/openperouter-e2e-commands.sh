#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ openperouter deploy-verify test ************"

# SHARED_DIR is the CI-provided workspace shared by all steps in the workflow.
# The baremetalds-e2e workflow's ofcir-acquire step writes packet-conf.sh there;
# it defines the leased host's IP and SSHOPTS and verifies root SSH access.
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

echo "### Copying OpenPERouter E2E source to remote host"
tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" \
  "mkdir -p /root/openperouter && tar -C /root/openperouter -xzf -"

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
