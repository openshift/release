#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

oc create namespace $NAMESPACE || true

if [[ -d "assisted-service-mcp" ]]; then
    cd assisted-service-mcp
    git fetch origin
    if [[ "$ASSISTED_MCP_GIT_BRANCH" == "master" ]]; then
        git rebase origin/$ASSISTED_MCP_GIT_BRANCH
    else
        git checkout $ASSISTED_MCP_GIT_BRANCH
    fi
fi

make deploy-template