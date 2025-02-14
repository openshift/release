#!/bin/bash
set -e

export HOME WORKSPACE
HOME=/tmp
WORKSPACE=$(pwd)
cd /tmp || exit

curl -Lo ocm https://github.com/openshift-online/ocm-cli/releases/latest/download/ocm-linux-amd64

# Prepare to git checkout
export GIT_PR_NUMBER GITHUB_ORG_NAME GITHUB_REPOSITORY_NAME TAG_NAME
GIT_PR_NUMBER=$(echo "${JOB_SPEC}" | jq -r '.refs.pulls[0].number')
echo "GIT_PR_NUMBER : $GIT_PR_NUMBER"
GITHUB_ORG_NAME="redhat-developer"
GITHUB_REPOSITORY_NAME="rhdh"

export RELEASE_BRANCH_NAME
export QUAY_REPO="rhdh-community/rhdh"
RELEASE_BRANCH_NAME=$(echo ${JOB_SPEC} | jq -r '.extra_refs[].base_ref')

# Clone and checkout the specific PR
git clone "https://github.com/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}.git"
cd "${GITHUB_REPOSITORY_NAME}" || exit
git checkout "$RELEASE_BRANCH_NAME" || exit

git config --global user.name "rhdh-qe"
git config --global user.email "rhdh-qe@redhat.com"

if [ "$JOB_TYPE" == "presubmit" ] && [[ "$JOB_NAME" != rehearse-* ]]; then
    # If executed as PR check of the repository, switch to PR branch.
    git fetch origin pull/"${GIT_PR_NUMBER}"/head:PR"${GIT_PR_NUMBER}"
    git checkout PR"${GIT_PR_NUMBER}"
    git merge origin/$RELEASE_BRANCH_NAME --no-edit
fi

echo "############## Current branch ##############"
echo "Current branch: $(git branch --show-current)"

export CLIENT_ID CLIENT_SECRET CLUSTER_NAME

CLIENT_ID=$(cat /tmp/osdsecrets/OSD_CLIENT_ID)
CLIENT_SECRET=$(cat /tmp/osdsecrets/OSD_CLIENT_SECRET)

CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-info.name")

bash ./.ibm/pipelines/cluster/osd-gcp/destroy-osd.sh
