#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Starting upstream sync process..."

# Clone the test-infra repository
git clone --single-branch --depth=1 --branch ${TEST_INFRA_BRANCH:-main} https://github.com/maistra/test-infra.git
cd test-infra

# Set up environment variables
export BUILD_WITH_CONTAINER="0"
export XDG_CACHE_HOME="/tmp/cache"
export GOCACHE="/tmp/cache"
export GOMODCACHE="/tmp/cache"
export GITHUB_TOKEN_PATH=/creds-github/token

echo "Running automator for openshift-service-mesh/sail-operator@${TARGET_BRANCH}..."

# Run the automator script
./tools/automator-main.sh \
    --org=openshift-service-mesh \
    --repo=sail-operator \
    --branch=${TARGET_BRANCH} \
    --token-path=/creds-github/token \
    "--title=Automator: merge upstream changes to $AUTOMATOR_ORG/$AUTOMATOR_REPO@$AUTOMATOR_BRANCH" \
    "--labels=auto-merge,tide/merge-method-merge" \
    --modifier=merge_upstream_main \
    --cmd=./ossm/merge_upstream.sh

echo "Upstream sync process completed."