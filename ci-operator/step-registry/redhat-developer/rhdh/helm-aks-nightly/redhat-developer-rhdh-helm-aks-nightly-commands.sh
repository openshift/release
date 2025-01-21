#!/bin/bash
export HOME WORKSPACE
HOME=/tmp
WORKSPACE=$(pwd)
cd /tmp || exit

echo "OC_CLIENT_VERSION: $OC_CLIENT_VERSION"

export GITHUB_ORG_NAME GITHUB_REPOSITORY_NAME NAME_SPACE TAG_NAME

GITHUB_ORG_NAME="redhat-developer"
GITHUB_REPOSITORY_NAME="rhdh"
TAG_NAME="next"

# Clone and checkout the specific PR
git clone "https://github.com/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}.git"
cd rhdh || exit

bash ./.ibm/pipelines/openshift-ci-tests.sh
