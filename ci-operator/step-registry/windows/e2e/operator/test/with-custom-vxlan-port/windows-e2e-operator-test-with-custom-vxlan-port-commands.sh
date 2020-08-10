#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export KUBE_SSH_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
make run-ci-e2e-test
