#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

oc create namespace $NAMESPACE || true

cd assisted-service-mcp
git fetch origin
if [[ "$ASSISTED_MCP_GIT_BRANCH" == "master" ]]; then
    git rebase origin/$ASSISTED_MCP_GIT_BRANCH
else
    git checkout $ASSISTED_MCP_GIT_BRANCH
fi

make deploy-template