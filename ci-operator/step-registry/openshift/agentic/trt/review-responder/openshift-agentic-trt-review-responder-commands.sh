#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Review Responder ==="

# --- Read tokens from SHARED_DIR ---
set +x
export GH_FORK_TOKEN=$(cat "${SHARED_DIR}/gh-fork-token")
export GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token")
JIRA_ISSUE_KEY=$(cat "${SHARED_DIR}/jira-issue-key")

git config --global credential.helper '!f() { echo username=x-access-token; echo "password=${GH_FORK_TOKEN}"; }; f'

# --- Find PR number ---
if [[ -f "${SHARED_DIR}/pr-number" ]]; then
    PR_NUM=$(cat "${SHARED_DIR}/pr-number")
    echo "PR number from SHARED_DIR: #${PR_NUM}"
else
    echo "Searching for PR associated with ${JIRA_ISSUE_KEY}..."
    PR_JSON=$(gh pr list --repo "${UPSTREAM_REPO}" --state open --search "${JIRA_ISSUE_KEY}" --json number --limit 1 2>/dev/null || echo "[]")
    PR_NUM=$(echo "${PR_JSON}" | jq -r '.[0].number // empty')
    if [[ -z "${PR_NUM}" ]]; then
        echo "No open PR found for ${JIRA_ISSUE_KEY}. Nothing to do."
        exit 0
    fi
    echo "Found PR #${PR_NUM}"
fi

# --- Workspace setup ---
cd /workspace
git config user.name "openshift-trt"
git config user.email "openshift-trt@redhat.com"
git remote add fork "https://github.com/${FORK_REPO}.git" 2>/dev/null || true

echo "Running setup script: ${SETUP_SCRIPT}..."
source "/workspace/${SETUP_SCRIPT}"

mkdir -p /workspace/artifacts

copy_artifacts() {
    echo "Copying artifacts..."
    cp /workspace/artifacts/* "${ARTIFACT_DIR}/" 2>/dev/null || true
    podman logs sippy-postgres > "${ARTIFACT_DIR}/postgres.log" 2>&1 || true
}
trap copy_artifacts EXIT TERM INT

# --- Trusted user filtering ---
TRUSTED_BOTS="coderabbitai"

is_trusted_user() {
    local login=$1
    for bot in ${TRUSTED_BOTS}; do
        [[ "${login}" == "${bot}" || "${login}" == "${bot}[bot]" ]] && return 0
    done
    local org="${UPSTREAM_REPO%%/*}"
    gh api "orgs/${org}/members/${login}" --silent 2>/dev/null && return 0
    echo "Skipping comment from untrusted user: ${login}"
    return 1
}

# --- Poll for review comments every 5 minutes for 30 minutes ---
echo "=== Watching PR #${PR_NUM} for review comments (6 checks, 5 min apart) ==="

for i in $(seq 1 6); do
    echo "Waiting 5 minutes before checking for comments (check $i/6)..."
    sleep 300

    raw_comments=$(gh api "repos/${UPSTREAM_REPO}/pulls/${PR_NUM}/comments" --paginate 2>/dev/null || echo "[]")
    raw_reviews=$(gh api "repos/${UPSTREAM_REPO}/pulls/${PR_NUM}/reviews" --paginate 2>/dev/null || echo "[]")

    all_users=$(echo "${raw_comments}" "${raw_reviews}" | jq -r '.[].user.login' 2>/dev/null | sort -u)
    trusted_users=""
    for user in ${all_users}; do
        if is_trusted_user "${user}"; then
            trusted_users="${trusted_users} ${user}"
        fi
    done

    trusted_jq_filter=$(echo "${trusted_users}" | xargs -n1 | jq -R . | jq -s '.')
    COMMENTS_JSON=$(echo "${raw_comments}" | jq --argjson trusted "${trusted_jq_filter}" '[.[] | select(.user.login as $u | $trusted | index($u))]')
    REVIEWS_JSON=$(echo "${raw_reviews}" | jq --argjson trusted "${trusted_jq_filter}" '[.[] | select(.user.login as $u | $trusted | index($u))]')

    comment_count=$(echo "${COMMENTS_JSON}" | jq 'length')
    review_count=$(echo "${REVIEWS_JSON}" | jq '[.[] | select(.state != "APPROVED" and .state != "PENDING")] | length')
    TOTAL=$(( comment_count + review_count ))

    echo "Found ${TOTAL} comment(s)/review(s) from trusted users."

    if [[ "${TOTAL}" -gt 0 ]]; then
        echo "Addressing review comments..."

        REVIEW_BODY=$(echo "${COMMENTS_JSON}" | jq -r '.[] | "**\(.user.login)** on `\(.path // "general")`:\n\(.body)\n---"' 2>/dev/null || echo "")
        REVIEW_SUMMARY=$(echo "${REVIEWS_JSON}" | jq -r '.[] | select(.state != "APPROVED" and .state != "PENDING") | "**\(.user.login)** (\(.state)):\n\(.body)\n---"' 2>/dev/null || echo "")

        timeout 1800 claude \
            --model "${CLAUDE_MODEL}" \
            --continue \
            --allowedTools "${ALLOWED_TOOLS}" \
            --output-format stream-json \
            --max-turns 50 \
            --append-system-prompt-file "/workspace/.apm/prompts/agentic-followup.prompt.md" \
            -p "${JIRA_ISSUE_KEY}" \
            --verbose 2>&1 | tee -a /workspace/artifacts/claude-output.log || true
    fi
done

echo "=== TRT Review Responder Complete ==="
