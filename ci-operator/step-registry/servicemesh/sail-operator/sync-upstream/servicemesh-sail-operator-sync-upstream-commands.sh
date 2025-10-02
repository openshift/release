#!/bin/bash

# ==============================================================================
# Upstream Sync Script
#
# This script synchronizes upstream changes from the main Sail Operator
# repository to the OpenShift Service Mesh downstream repository.
#
# It performs the following steps:
# 1. Clones the maistra/test-infra repository from the specified branch.
# 2. Sets up the build environment with container-free builds and caching.
# 3. Configures GitHub authentication using the provided token.
# 4. Executes the automator tool to merge upstream changes into the target
#    downstream repository and branch.
# 5. Creates a pull request with auto-merge labels for the synchronized changes.
#
# Required Environment Variables:
#   - TARGET_BRANCH: The target branch in the downstream repository to sync to.
#   - AUTOMATOR_ORG: The organization name for the automator process.
#   - AUTOMATOR_REPO: The repository name for the automator process.
#   - AUTOMATOR_BRANCH: The branch name for the automator process.
#
# Optional Environment Variables:
#   - TEST_INFRA_BRANCH: The branch of test-infra to use (default: main).
#
# Required Files:
#   - /creds-github/token: GitHub authentication token file.
# ==============================================================================

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