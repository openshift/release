#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

export SSH_PRIVATE_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey

echo "Get the installer gather logs if it is around"

dir=/tmp/installer

openshift-install gather bootstrap --dir=${dir} --key "${SSH_PRIVATE_KEY_PATH}" || true
