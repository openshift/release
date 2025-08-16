#!/bin/bash
# Create an ARO HCP Cluster + Node pool using bicep.
set -o errexit
set -o nounset
set -o pipefail

COMPARISON_BASE=${COMPARISON_BASE:-${PULL_BASE_SHA:-"master"}}

merge_commits_in_PR_branch=$(git log --oneline --merges "${PULL_BASE_SHA}"..HEAD)
if [ -n "$merge_commits_in_PR_branch" ]; then
    echo "Merge commits are not allowed as part of the PR branch: ${PULL_BASE_SHA}..HEAD"
    echo "$merge_commits_in_PR_branch"
    exit 1
fi

