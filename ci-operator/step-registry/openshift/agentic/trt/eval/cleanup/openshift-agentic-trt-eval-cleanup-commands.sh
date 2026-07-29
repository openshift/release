#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Eval Cleanup ==="

set +x
GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token" 2>/dev/null || echo "")
export GITHUB_TOKEN
set -x

if [[ -z "${GITHUB_TOKEN}" ]]; then
    echo "No token available, skipping cleanup."
    exit 0
fi

if [[ ! -f "${SHARED_DIR}/eval-cases" ]]; then
    echo "No eval-cases file found, skipping cleanup."
    exit 0
fi

mapfile -t CASE_LIST < "${SHARED_DIR}/eval-cases"
echo "Cleaning up ${#CASE_LIST[@]} cases..."

for case_name in "${CASE_LIST[@]}"; do
    PR_NUM=""
    if [[ -f "${SHARED_DIR}/${case_name}.pr-number" ]]; then
        PR_NUM=$(cat "${SHARED_DIR}/${case_name}.pr-number")
    fi

    if [[ -n "${PR_NUM}" ]]; then
        echo "[${case_name}] Closing PR #${PR_NUM} and deleting branch..."
        gh pr close "${PR_NUM}" --repo "${UPSTREAM_REPO}" --delete-branch 2>/dev/null || true
    else
        CLAUDE_BRANCH=""
        if [[ -f "${SHARED_DIR}/${case_name}.claude-branch" ]]; then
            CLAUDE_BRANCH=$(cat "${SHARED_DIR}/${case_name}.claude-branch")
        fi
        if [[ -n "${CLAUDE_BRANCH}" ]]; then
            echo "[${case_name}] No PR found, deleting branch ${CLAUDE_BRANCH}..."
            gh api "repos/${UPSTREAM_REPO}/git/refs/heads/${CLAUDE_BRANCH}" -X DELETE 2>/dev/null || true
        else
            echo "[${case_name}] Nothing to clean up."
        fi
    fi
done

echo "=== TRT Eval Cleanup Complete ==="
