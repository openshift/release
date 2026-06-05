#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT PR Followup ==="

source "${SHARED_DIR}/trt-common.sh"
load_jira_issue
generate_github_tokens || exit 1

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

export PR_NUM=$(echo "${PR_JSON}" | jq -r '.[0].number')
export PR_TITLE=$(echo "${PR_JSON}" | jq -r '.[0].title')
export PR_BRANCH=$(echo "${PR_JSON}" | jq -r '.[0].headRefName')
export PR_URL=$(echo "${PR_JSON}" | jq -r '.[0].url')
echo "Found PR #${PR_NUM}: ${PR_TITLE} | Branch: ${PR_BRANCH}"

# --- Fetch review comments ---
set +e
fetch_trusted_review_comments "${PR_NUM}" "${UPSTREAM_REPO}"
TOTAL=$?
set -e

if [[ "${TOTAL}" -eq 0 ]]; then
    echo "No review comments to address. Nothing to do."
    exit 0
fi

setup_artifact_trap
setup_workspace

# Check out PR branch
echo "Checking out PR branch ${PR_BRANCH}..."
git fetch fork "${PR_BRANCH}"
git checkout -b "${PR_BRANCH}" "fork/${PR_BRANCH}"

# --- Run Claude ---
echo "Invoking Claude to address review comments..."
generate_github_tokens || echo "Warning: Failed to refresh tokens."

CLAUDE_EXIT=0
timeout 5400 claude \
    --model "${CLAUDE_MODEL}" \
    --allowedTools "${ALLOWED_TOOLS}" \
    --output-format stream-json \
    --max-turns 100 \
    -p "/agentic-followup ${JIRA_ISSUE_KEY}" \
    --verbose 2>&1 | tee /workspace/artifacts/claude-output.log || CLAUDE_EXIT=$?

if [[ "${CLAUDE_EXIT}" -eq 124 ]]; then
    echo "Claude timed out. Nudging to wrap up..."
    timeout 600 claude \
        --model "${CLAUDE_MODEL}" \
        --continue \
        --allowedTools "${ALLOWED_TOOLS}" \
        --output-format stream-json \
        --max-turns 10 \
        -p "You hit the timeout. Please commit and push whatever fixes you have now: git push fork HEAD" \
        --verbose 2>&1 | tee -a /workspace/artifacts/claude-output.log || true
fi

echo "=== TRT PR Followup Complete ==="
