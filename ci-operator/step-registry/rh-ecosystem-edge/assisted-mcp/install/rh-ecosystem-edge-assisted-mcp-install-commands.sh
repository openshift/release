#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

ensure_mcp_repo() {
    if [[ ! -d "assisted-service-mcp" ]]; then
        git clone https://github.com/openshift-assisted/assisted-service-mcp.git
    fi  

    cd assisted-service-mcp
    git fetch origin
    if [[ "$ASSISTED_MCP_GIT_BRANCH" == "master" ]]; then
        git rebase origin/$ASSISTED_MCP_GIT_BRANCH
    else
        git checkout $ASSISTED_MCP_GIT_BRANCH
    fi  
}

oc create namespace $NAMESPACE || true

if [[ "${PWD##*/}" != "assisted-service-mcp" ]]; then
    ensure_mcp_repo
fi

current_commit_sha=$(git rev-parse HEAD)
echo "The current commit hash is: ${current_commit_sha}"
current_branch=$(git rev-parse --abbrev-ref HEAD)
echo "The current branch is: ${current_branch}"

make deploy-template