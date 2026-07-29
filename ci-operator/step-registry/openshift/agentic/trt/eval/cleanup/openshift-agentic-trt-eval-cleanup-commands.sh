#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Eval Cleanup ==="

set +x
GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token" 2>/dev/null || echo "")
export GITHUB_TOKEN
set -x

PR_NUM=""
if [[ -f "${SHARED_DIR}/pr-number" ]]; then
    PR_NUM=$(cat "${SHARED_DIR}/pr-number")
fi

if [[ -n "${PR_NUM}" && -n "${GITHUB_TOKEN}" ]]; then
    echo "Closing eval PR #${PR_NUM} and deleting branch..."
    gh pr close "${PR_NUM}" --repo "${UPSTREAM_REPO}" --delete-branch 2>/dev/null || true
elif [[ -n "${GITHUB_TOKEN}" ]]; then
    CLAUDE_BRANCH=""
    if [[ -f "${SHARED_DIR}/claude-branch" ]]; then
        CLAUDE_BRANCH=$(cat "${SHARED_DIR}/claude-branch")
    fi
    if [[ -n "${CLAUDE_BRANCH}" ]]; then
        echo "No PR found, deleting branch ${CLAUDE_BRANCH} directly..."
        gh api "repos/${UPSTREAM_REPO}/git/refs/heads/${CLAUDE_BRANCH}" -X DELETE 2>/dev/null || true
    fi
else
    echo "No token available, skipping cleanup."
fi

echo "=== TRT Eval Cleanup Complete ==="
