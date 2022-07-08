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

sleep 600

# fetch pull-secret for the central CI registry
mkdir -p ~/.docker
oc registry login --registry-config="${HOME}/.docker/config.json"

# call the rebase script
echo "./scripts/rebase.sh to ${TARGET_RELEASE_IMAGE}"
./scripts/rebase.sh to "${TARGET_RELEASE_IMAGE}"
