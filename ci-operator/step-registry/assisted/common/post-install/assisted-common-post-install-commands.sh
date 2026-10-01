#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ assisted common post-install command ************"

timeout -s 9 175m ssh -F ${SHARED_DIR}/ssh_config ci_machine bash - << EOF |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
set -xeuo pipefail
cd /home/assisted
# Tracing is disabled while config.sh is sourced, otherwise xtrace expands
# PULL_SECRET and the platform credentials it pulls in from platform-conf.sh
# (VSPHERE_PASSWORD, NUTANIX_PASSWORD) into the publicly readable build log.
set +x
source /root/config.sh
set -x
echo "export KUBECONFIG=/home/assisted/build/kubeconfig" >> /root/.bashrc
export KUBECONFIG=/home/assisted/build/kubeconfig
source /root/assisted-post-install.sh
EOF

echo "### Copying kubeconfig files"
export KUBECONFIG=${SHARED_DIR}/kubeconfig
ssh -F "${SHARED_DIR}/ssh_config" "root@ci_machine" "find \${KUBECONFIG} -type f -exec cat {} \;" > ${KUBECONFIG}
