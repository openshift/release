#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ assisted common post-install command ************"

timeout -s 9 175m ssh -F ${SHARED_DIR}/ssh_config ci_machine bash - << EOF |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
set -xeuo pipefail
cd /home/assisted
source /root/config.sh
echo "export KUBECONFIG=/home/assisted/build/kubeconfig" >> /root/.bashrc
export KUBECONFIG=/home/assisted/build/kubeconfig
source /root/assisted-post-install.sh
EOF

echo "### Copying kubeconfig files"
export KUBECONFIG=${SHARED_DIR}/kubeconfig
ssh -F "${SHARED_DIR}/ssh_config" "root@ci_machine" "find \${KUBECONFIG} -type f -exec cat {} \;" > ${KUBECONFIG}

until \
  oc wait --all=true clusteroperator --for='condition=Available=True' >/dev/null && \
  oc wait --all=true clusteroperator --for='condition=Progressing=False' >/dev/null && \
  oc wait --all=true clusteroperator --for='condition=Degraded=False' >/dev/null;  do
    echo "$(date --rfc-3339=seconds) Clusteroperators not yet ready"
    sleep 1s
done
