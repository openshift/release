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

echo "Running automator for ${TARGET_ORG}/${TARGET_REPO}@${TARGET_BRANCH}..."

# Run the automator script
./tools/automator-main.sh \
    --org=${TARGET_ORG} \
    --repo=${TARGET_REPO} \
    --branch=${TARGET_BRANCH} \
    --token-path=/creds-github/token \
    "--title=${PR_TITLE}" \
    "--labels=${PR_LABELS}" \
    --modifier=${MODIFIER} \
    --cmd=${MERGE_SCRIPT}

echo "Upstream sync process completed."