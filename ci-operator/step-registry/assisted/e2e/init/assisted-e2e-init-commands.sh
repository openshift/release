#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# # TODO: Also on multistage test the shared directory is currently
# # read-only, so some oc commands might fail to read the kubeconfig file.
# ASSISTED_SHARED_DIR=/tmp/shared_dir
# mkdir -p $ASSISTED_SHARED_DIR
# cp -f ${SHARED_DIR}/* ${ASSISTED_SHARED_DIR}
# export KUBECONFIG=${ASSISTED_SHARED_DIR}/kubeconfig

echo "test"
oc whoami
cat /etc/os-release
oc get pods -o wide