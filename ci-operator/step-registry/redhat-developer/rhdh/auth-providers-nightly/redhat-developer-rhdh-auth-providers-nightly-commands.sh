#!/bin/bash
export HOME WORKSPACE
HOME=/tmp
WORKSPACE=$(pwd)
cd /tmp || exit

echo "OC_CLIENT_VERSION: $OC_CLIENT_VERSION"

export GITHUB_ORG_NAME GITHUB_REPOSITORY_NAME NAME_SPACE TAG_NAME

GITHUB_ORG_NAME="redhat-developer"
GITHUB_REPOSITORY_NAME="rhdh"

export QUAY_REPO RELEASE_BRANCH_NAME
QUAY_REPO="rhdh/rhdh-hub-rhel9"
    
# Get the base branch name based on job.
RELEASE_BRANCH_NAME=$(echo ${JOB_SPEC} | jq -r '.extra_refs[].base_ref' 2>/dev/null || echo ${JOB_SPEC} | jq -r '.refs.base_ref')
if [ "${RELEASE_BRANCH_NAME}" != "main" ]; then
    # Get branch a specific tag name (e.g., 'release-1.5' becomes '1.5')
    TAG_NAME="$(echo $RELEASE_BRANCH_NAME | cut -d'-' -f2)"
else
    TAG_NAME="next"
fi

# Clone and checkout the specific PR
git clone "https://github.com/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}.git"
cd "${GITHUB_REPOSITORY_NAME}" || exit
git checkout "$RELEASE_BRANCH_NAME" || exit

echo "############## Current branch ##############"
echo "Current branch: $(git branch --show-current)"
echo "Using Image: ${QUAY_REPO}:${TAG_NAME}"

bash ./.ibm/pipelines/openshift-ci-tests.sh
