#!/bin/bash
export HOME WORKSPACE
HOME=/tmp
cd /tmp || exit
WORKSPACE=$(pwd)

curl -Lo ocm https://github.com/openshift-online/ocm-cli/releases/latest/download/ocm-linux-amd64

export CLUSTER_NAME
CLUSTER_NAME="osd-$(date +%s)"

echo "CLUSTER_NAME : $CLUSTER_NAME"

# Prepare to git checkout
export GIT_PR_NUMBER GITHUB_ORG_NAME GITHUB_REPOSITORY_NAME TAG_NAME
GIT_PR_NUMBER=$(echo "${JOB_SPEC}" | jq -r '.refs.pulls[0].number')
echo "GIT_PR_NUMBER : $GIT_PR_NUMBER"
GITHUB_ORG_NAME="redhat-developer"
GITHUB_REPOSITORY_NAME="rhdh"

export RELEASE_BRANCH_NAME
export QUAY_REPO="rhdh-community/rhdh"
# Get the base branch name based on job.
RELEASE_BRANCH_NAME=$(echo ${JOB_SPEC} | jq -r '.extra_refs[].base_ref' 2>/dev/null || echo ${JOB_SPEC} | jq -r '.refs.base_ref')

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

bash ./.ibm/pipelines/cluster/osd-gcp/create-osd.sh

cp -v /tmp/rhdh/osdcluster/cluster-info.name "${SHARED_DIR}/"
cp -v /tmp/rhdh/osdcluster/cluster-info.id "${SHARED_DIR}/"
cp -v /tmp/rhdh/osdcluster/kubeconfig "${SHARED_DIR}/"

