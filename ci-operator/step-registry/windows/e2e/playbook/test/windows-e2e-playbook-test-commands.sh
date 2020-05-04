#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cluster_profile=/var/run/secrets/ci.openshift.io/cluster-profile
export AWS_SHARED_CREDENTIALS_FILE=${cluster_profile}/.awscred
export KUBE_SSH_KEY_PATH=${cluster_profile}/ssh-privatekey
make run-wsu-ci-e2e-test
