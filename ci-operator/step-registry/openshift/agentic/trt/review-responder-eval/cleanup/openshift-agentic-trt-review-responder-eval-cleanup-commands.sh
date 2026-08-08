#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Review Responder Eval Cleanup ==="

set +x
GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token" 2>/dev/null || echo "")
export GITHUB_TOKEN
set -x

if [[ -z "${GITHUB_TOKEN}" ]]; then
    echo "No token available, skipping cleanup."
    exit 0
fi

PR_NUM=""
if [[ -f "${SHARED_DIR}/pr-number" ]]; then
    PR_NUM=$(cat "${SHARED_DIR}/pr-number")
fi

EVAL_BRANCH=""
if [[ -f "${SHARED_DIR}/eval-head-branch" ]]; then
    EVAL_BRANCH=$(cat "${SHARED_DIR}/eval-head-branch")
fi

if [[ -n "${PR_NUM}" ]]; then
    echo "Closing PR #${PR_NUM} and deleting branch..."
    gh pr close "${PR_NUM}" --repo "${UPSTREAM_REPO}" --delete-branch || true
elif [[ -n "${EVAL_BRANCH}" ]]; then
    echo "No PR found, deleting branch ${EVAL_BRANCH}..."
    gh api "repos/${UPSTREAM_REPO}/git/refs/heads/${EVAL_BRANCH}" -X DELETE || true
else
    echo "Nothing to clean up."
fi

echo "=== TRT Review Responder Eval Cleanup Complete ==="
