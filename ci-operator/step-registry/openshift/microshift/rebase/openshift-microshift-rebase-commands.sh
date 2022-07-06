#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Environment:"
printenv

echo "Credentials:"
export PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
ls -al /secrets/ci-pull-credentials || true
ls -al /etc/pull-secret || true
ls -al "${PULL_SECRET_PATH}"/etc/pull-secret || true

mkdir ~/.docker
cp "${PULL_SECRET_PATH}"/.dockerconfigjson ~/.docker/config.json || true

echo "./scripts/rebase.sh to ${TARGET_RELEASE_IMAGE}"
./scripts/rebase.sh to "${TARGET_RELEASE_IMAGE}"
