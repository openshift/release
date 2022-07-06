#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# print info on environment and tools
echo "Environment:"
printenv

echo "Tool versions:"
echo "  git: $(git version)"
echo "  go: $(go version)"
echo "  jq: $(jq --version)"
echo "  oc: $(oc version)"

# copy pull secret to the location needed for `oc adm`
mkdir -p ~/.docker
cp "${CLUSTER_PROFILE_DIR}"/pull-secret ~/.docker/config.json

# call the rebase script
echo "./scripts/rebase.sh to ${TARGET_RELEASE_IMAGE}"
./scripts/rebase.sh to "${TARGET_RELEASE_IMAGE}"
