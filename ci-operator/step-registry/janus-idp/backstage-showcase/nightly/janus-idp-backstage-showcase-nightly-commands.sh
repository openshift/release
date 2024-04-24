#!/bin/bash
export HOME WORKSPACE
HOME=/tmp
WORKSPACE=$(pwd)
cd /tmp || exit

export GITHUB_ORG_NAME GITHUB_REPOSITORY_NAME NAME_SPACE TAG_NAME

GITHUB_ORG_NAME="janus-idp"
GITHUB_REPOSITORY_NAME="backstage-showcase"
NAME_SPACE=showcase-ci
TAG_NAME="next"

# Clone and checkout the specific PR
git clone "https://github.com/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}.git"
cd backstage-showcase || exit

IMAGE_NAME="${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}:${TAG_NAME}"

bash ./.ibm/pipelines/openshift-ci-tests.sh
