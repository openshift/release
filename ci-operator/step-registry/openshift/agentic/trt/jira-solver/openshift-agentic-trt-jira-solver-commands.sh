#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Jira Solver ==="

source "${SHARED_DIR}/trt-common.sh"
load_jira_issue
generate_github_tokens || exit 1
setup_artifact_trap
setup_workspace

# --- Run Claude ---
echo "Invoking Claude to solve ${JIRA_ISSUE_KEY}..."

CLAUDE_EXIT=0
timeout 5400 claude \
    --model "${CLAUDE_MODEL}" \
    --allowedTools "${ALLOWED_TOOLS}" \
    --output-format stream-json \
    --max-turns 100 \
    -p "/agentic-solve ${JIRA_ISSUE_KEY}" \
    --verbose 2>&1 | tee /workspace/artifacts/claude-output.log || CLAUDE_EXIT=$?

if [[ "${CLAUDE_EXIT}" -eq 124 ]]; then
    echo "Claude timed out. Nudging to wrap up..."
    timeout 600 claude \
        --model "${CLAUDE_MODEL}" \
        --continue \
        --allowedTools "${ALLOWED_TOOLS}" \
        --output-format stream-json \
        --max-turns 10 \
        -p "You hit the timeout. Please wrap up immediately: commit whatever you have, push to fork, and write the PR description to /workspace/artifacts/pr-description.md." \
        --verbose 2>&1 | tee -a /workspace/artifacts/claude-output.log || true
fi

# --- Create PR ---
BRANCH_NAME=$(git branch --show-current 2>/dev/null || echo "")
if [[ -z "${BRANCH_NAME}" || "${BRANCH_NAME}" == "main" || "${BRANCH_NAME}" == "master" ]]; then
    echo "ERROR: Claude did not create a feature branch."
    exit 1
fi
echo "Branch pushed: ${BRANCH_NAME}"

generate_github_tokens || { echo "ERROR: Failed to refresh tokens for PR creation."; exit 1; }

PR_BODY_FILE="/workspace/artifacts/pr-description.md"
if [[ ! -s "${PR_BODY_FILE}" ]]; then
    echo "Warning: No PR description generated. Using default."
    cat > "${PR_BODY_FILE}" <<PR_DEFAULT
## ${JIRA_ISSUE_KEY}: ${ISSUE_SUMMARY}

Fixes: https://redhat.atlassian.net/browse/${JIRA_ISSUE_KEY}
PR_DEFAULT
fi
printf '\n---\nGenerated with [Claude Code](https://claude.com/claude-code)\n' >> "${PR_BODY_FILE}"

echo "Creating PR..."
PR_URL=$(gh pr create \
    --repo "${UPSTREAM_REPO}" \
    --head "${FORK_REPO%%/*}:${BRANCH_NAME}" \
    --no-maintainer-edit \
    --title "${JIRA_ISSUE_KEY}: $(echo "${ISSUE_SUMMARY}" | head -c 60)" \
    --body-file "${PR_BODY_FILE}" \
    2>&1) || {
    echo "ERROR: Failed to create PR: ${PR_URL}"
    exit 1
}

echo "PR created: ${PR_URL}"
PR_NUM=$(echo "${PR_URL}" | grep -o '[0-9]*$')

# --- Poll for review comments (1 hour) ---
echo ""
echo "=== Watching PR #${PR_NUM} for review comments (up to 1 hour) ==="

for i in $(seq 1 6); do
    echo "Waiting 10 minutes before checking for comments (check $i/6)..."
    sleep 600

    set +e
    fetch_trusted_review_comments "${PR_NUM}" "${UPSTREAM_REPO}"
    TOTAL=$?
    set -e

    if [[ "${TOTAL}" -gt 0 ]]; then
        echo "Addressing review comments..."
        generate_github_tokens || echo "Warning: Failed to refresh tokens."

        timeout 1800 claude \
            --model "${CLAUDE_MODEL}" \
            --continue \
            --allowedTools "${ALLOWED_TOOLS}" \
            --output-format stream-json \
            --max-turns 50 \
            -p "Review comments have been posted on the PR. Address all of them, then push your fixes to the fork.

For each comment you address, reply to it on the PR using: gh api repos/${UPSTREAM_REPO}/pulls/${PR_NUM}/comments/COMMENT_ID/replies -f body='<your response>'
Explain what you changed and why. If a comment is not actionable, reply explaining why.

${REVIEW_BODY}
${REVIEW_SUMMARY}

After fixing, run tests to verify. Then push: git push fork HEAD" \
            --verbose 2>&1 | tee -a /workspace/artifacts/claude-output.log || true
    fi
done

echo "=== TRT Jira Solver Complete ==="
