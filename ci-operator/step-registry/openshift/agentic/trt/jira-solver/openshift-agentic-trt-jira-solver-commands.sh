#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Jira Solver ==="

# --- Read tokens and issue from SHARED_DIR (written by init pre-step) ---
set +x
GH_FORK_TOKEN=$(cat "${SHARED_DIR}/gh-fork-token")
export GH_FORK_TOKEN
GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token")
export GITHUB_TOKEN
JIRA_ISSUE_KEY=$(cat "${SHARED_DIR}/jira-issue-key")
export JIRA_ISSUE_KEY
ISSUE_JSON="${SHARED_DIR}/jira-issue.json"
ISSUE_SUMMARY=$(jq -r '.fields.summary // "No summary"' "${ISSUE_JSON}")
export ISSUE_SUMMARY

git config --global credential.helper '!f() { echo username=x-access-token; echo "password=${GH_FORK_TOKEN}"; }; f'

echo "Issue: ${JIRA_ISSUE_KEY} | Upstream: ${UPSTREAM_REPO} | Fork: ${FORK_REPO}"

# --- Workspace setup ---
cd /workspace
git config user.name "openshift-trt"
git config user.email "openshift-trt@redhat.com"
git remote add fork "https://github.com/${FORK_REPO}.git"

echo "Running setup script: ${SETUP_SCRIPT}..."
# shellcheck source=/dev/null
source "/workspace/${SETUP_SCRIPT}"

mkdir -p /workspace/artifacts

copy_artifacts() {
    echo "Copying artifacts..."
    cp /workspace/artifacts/* "${ARTIFACT_DIR}/" 2>/dev/null || true
    podman logs sippy-postgres > "${ARTIFACT_DIR}/postgres.log" 2>&1 || true
    if [[ -d "${HOME}/.claude/projects" ]]; then
        echo "Archiving Claude session logs..."
        tar -czf "${ARTIFACT_DIR}/claude-sessions-$(date +%Y%m%d-%H%M%S).tar.gz" -C "${HOME}/.claude" projects/ 2>/dev/null || true
    fi
}
trap copy_artifacts EXIT TERM INT

# --- Run Claude ---
echo "Invoking Claude to solve ${JIRA_ISSUE_KEY}..."

CLAUDE_EXIT=0
timeout 5400 claude \
    --model "${CLAUDE_MODEL}" \
    --allowedTools "${ALLOWED_TOOLS}" \
    --output-format stream-json \
    --max-turns 100 \
    --append-system-prompt-file "/workspace/.apm/prompts/agentic-solve.prompt.md" \
    -p "Solve Jira issue ${JIRA_ISSUE_KEY}" \
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
elif [[ "${CLAUDE_EXIT}" -ne 0 ]]; then
    echo "ERROR: Claude exited with code ${CLAUDE_EXIT}."
    exit "${CLAUDE_EXIT}"
fi

# --- Create PR ---
BRANCH_NAME=$(git branch --show-current 2>/dev/null || echo "")
if [[ -z "${BRANCH_NAME}" || "${BRANCH_NAME}" == "main" || "${BRANCH_NAME}" == "master" ]]; then
    echo "ERROR: Claude did not create a feature branch."
    exit 1
fi
echo "Branch pushed: ${BRANCH_NAME}"

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
    --title "$(echo "${JIRA_ISSUE_KEY}: ${ISSUE_SUMMARY}" | head -c 250)" \
    --body-file "${PR_BODY_FILE}" \
    2>&1) || {
    echo "ERROR: Failed to create PR: ${PR_URL}"
    exit 1
}

echo "PR created: ${PR_URL}"
PR_NUM=$(echo "${PR_URL}" | grep -o '[0-9]*$')
echo "${PR_NUM}" > "${SHARED_DIR}/pr-number"

# Trigger CodeRabbit review
gh pr comment "${PR_NUM}" --repo "${UPSTREAM_REPO}" --body "@coderabbitai review" 2>/dev/null || echo "Warning: Failed to trigger CodeRabbit review."

echo "=== TRT Jira Solver Complete ==="
