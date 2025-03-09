#!/bin/bash
export HOME WORKSPACE
HOME=/tmp
WORKSPACE=$(pwd)
cd /tmp || exit

export GITHUB_ORG_NAME GITHUB_REPOSITORY_NAME QUAY_REPO TAG_NAME

GITHUB_ORG_NAME="redhat-developer"
GITHUB_REPOSITORY_NAME="rhdh"
QUAY_REPO="rhdh/rhdh-hub-rhel9"
TAG_NAME="1.3"

# Clone and checkout the specific PR
git clone "https://github.com/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}.git"
cd rhdh || exit
git checkout "release-1.3" || exit

bash ./.ibm/pipelines/openshift-ci-tests.sh
