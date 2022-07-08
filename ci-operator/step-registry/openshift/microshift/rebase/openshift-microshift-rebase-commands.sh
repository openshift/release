#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

# print info on environment and tools
echo "Environment:"
printenv

echo "Tool versions:"
echo "  git: $(git version)"
echo "  go: $(go version)"
echo "  jq: $(jq --version)"
echo "  oc: $(oc version)"

oc get configmaps

sleep 1800

# fetch pull-secret for the central CI registry
mkdir -p ~/.docker
oc registry login --registry-config="${HOME}/.docker/config.json"

TARGET_RELEASE_IMAGE="quay.io/openshift-release-dev/ocp-release:4.10.18-x86_64"
# call the rebase script
echo "./scripts/rebase.sh to ${TARGET_RELEASE_IMAGE}"
./scripts/rebase.sh to "${TARGET_RELEASE_IMAGE}"
