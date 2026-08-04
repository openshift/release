#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT PR Followup ==="

# --- Read tokens from SHARED_DIR ---
set +x
GH_FORK_TOKEN=$(cat "${SHARED_DIR}/gh-fork-token")
export GH_FORK_TOKEN
GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token")
export GITHUB_TOKEN
JIRA_ISSUE_KEY=$(cat "${SHARED_DIR}/jira-issue-key")

git config --global credential.helper '!f() { echo username=x-access-token; echo "password=${GH_FORK_TOKEN}"; }; f'

# --- Find PR ---
echo "Searching for PR associated with ${JIRA_ISSUE_KEY}..."
PR_JSON=$(gh pr list --repo "${UPSTREAM_REPO}" --state open --search "${JIRA_ISSUE_KEY}" --json number,title,headRefName,url --limit 5 2>/dev/null || echo "[]")
if [[ $(echo "${PR_JSON}" | jq 'length') -eq 0 ]]; then
    echo "No open PR found. Searching closed PRs..."
    PR_JSON=$(gh pr list --repo "${UPSTREAM_REPO}" --state closed --search "${JIRA_ISSUE_KEY}" --json number,title,headRefName,url --limit 5 2>/dev/null || echo "[]")
fi
if [[ $(echo "${PR_JSON}" | jq 'length') -eq 0 ]]; then
    echo "ERROR: No PR found for ${JIRA_ISSUE_KEY}."; exit 1;
fi

PR_NUM=$(echo "${PR_JSON}" | jq -r '.[0].number')
PR_BRANCH=$(echo "${PR_JSON}" | jq -r '.[0].headRefName')
echo "Found PR #${PR_NUM} | Branch: ${PR_BRANCH}"

# Persist for review-responder step
echo "${PR_NUM}" > "${SHARED_DIR}/pr-number"

# --- Check out PR branch ---
cd /workspace
git config user.name "openshift-trt"
git config user.email "openshift-trt@redhat.com"
git remote add fork "https://github.com/${FORK_REPO}.git"

if ! git ls-remote --exit-code fork "refs/heads/${PR_BRANCH}" >/dev/null 2>&1; then
    echo "PR #${PR_NUM} branch ${PR_BRANCH} not found on fork. Nothing to do."
    exit 0
fi

git fetch fork "${PR_BRANCH}"
git checkout -b "${PR_BRANCH}" "fork/${PR_BRANCH}"

echo "=== TRT PR Followup Complete ==="
