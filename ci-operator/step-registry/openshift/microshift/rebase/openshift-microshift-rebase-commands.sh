#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Environment:"
printenv

echo "Credentials:"
ls -al /secrets/ci-pull-credentials || true
ls -al /etc/pull-secret || true

mkdir ~/.docker
cp /etc/ci-pull-credentials/.dockerconfigjson ~/.docker/config.json || true

echo "./scripts/rebase.sh to ${TARGET_RELEASE_IMAGE}"
./scripts/rebase.sh to "${TARGET_RELEASE_IMAGE}"
