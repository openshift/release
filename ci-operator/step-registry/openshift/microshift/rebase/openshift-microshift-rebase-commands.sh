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

# fetch pull-secret for the central CI registry
mkdir -p ~/.docker
oc --namespace microshift registry login --service-account image-puller --registry-config="${HOME}/.docker/config.json"

# call the rebase script
echo "./scripts/rebase.sh to ${TARGET_RELEASE_IMAGE}"
./scripts/rebase.sh to "${TARGET_RELEASE_IMAGE}"
