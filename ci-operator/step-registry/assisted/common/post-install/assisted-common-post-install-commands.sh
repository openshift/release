#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ assisted common post-install command ************"

# TODO: Remove once OpenShift CI will be upgraded to 4.2 (see https://access.redhat.com/articles/4859371)
~/fix_uid.sh

timeout -s 9 175m ssh -F ${SHARED_DIR}/ssh_config ci_machine bash - << EOF |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
set -xeuo pipefail
cd /home/assisted
source /root/config.sh
echo "export KUBECONFIG=/home/assisted/build/kubeconfig" >> /root/.bashrc
export KUBECONFIG=/home/assisted/build/kubeconfig
source /root/assisted-post-install.sh
EOF

echo "### Copying kubeconfig files"
scp -F "${SHARED_DIR}/ssh_config" -r "root@ci_machine:/home/assisted/build/kubeconfig/*" "${SHARED_DIR}" || true
