#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Review Responder ==="

# --- Read tokens from SHARED_DIR ---
set +x
GH_FORK_TOKEN=$(cat "${SHARED_DIR}/gh-fork-token")
export GH_FORK_TOKEN
GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token")
export GITHUB_TOKEN
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

# --- Poll for review comments and CI failures ---
echo "=== Watching PR #${PR_NUM} for review comments and CI failures ==="

PROCESSED_IDS=""
LAST_FAILING_NAMES=""
iteration=0
idle_streak=0

while true; do
    iteration=$(( iteration + 1 ))
    echo "Waiting 5 minutes before checking (iteration ${iteration})..."
    sleep 300

    # --- Fetch comments from all three GitHub endpoints ---
    raw_inline_comments=$(gh api "repos/${UPSTREAM_REPO}/pulls/${PR_NUM}/comments" --paginate 2>/dev/null || echo "[]")
    raw_reviews=$(gh api "repos/${UPSTREAM_REPO}/pulls/${PR_NUM}/reviews" --paginate 2>/dev/null || echo "[]")
    raw_issue_comments=$(gh api "repos/${UPSTREAM_REPO}/issues/${PR_NUM}/comments" --paginate 2>/dev/null || echo "[]")

    # Filter to trusted users
    all_users=$(echo "${raw_inline_comments}" "${raw_reviews}" "${raw_issue_comments}" | jq -r '.[].user.login' 2>/dev/null | sort -u)
    trusted_users=""
    for user in ${all_users}; do
        if is_trusted_user "${user}"; then
            trusted_users="${trusted_users} ${user}"
        fi
    done

    trusted_jq_filter=$(echo "${trusted_users}" | xargs -n1 | jq -R . | jq -s '.')
    INLINE_JSON=$(echo "${raw_inline_comments}" | jq --argjson trusted "${trusted_jq_filter}" '[.[] | select(.user.login as $u | $trusted | index($u))]')
    REVIEWS_JSON=$(echo "${raw_reviews}" | jq --argjson trusted "${trusted_jq_filter}" '[.[] | select(.user.login as $u | $trusted | index($u))]')
    ISSUE_COMMENTS_JSON=$(echo "${raw_issue_comments}" | jq --argjson trusted "${trusted_jq_filter}" '[.[] | select(.user.login as $u | $trusted | index($u))]')

    # Filter out already-processed items
    if [[ -n "${PROCESSED_IDS}" ]]; then
        processed_jq_filter=$(echo "${PROCESSED_IDS}" | tr ' ' '\n' | jq -R . | jq -s '.')
        INLINE_JSON=$(echo "${INLINE_JSON}" | jq --argjson seen "${processed_jq_filter}" '[.[] | select((.id | tostring) as $id | $seen | index($id) | not)]')
        REVIEWS_JSON=$(echo "${REVIEWS_JSON}" | jq --argjson seen "${processed_jq_filter}" '[.[] | select((.id | tostring) as $id | $seen | index($id) | not)]')
        ISSUE_COMMENTS_JSON=$(echo "${ISSUE_COMMENTS_JSON}" | jq --argjson seen "${processed_jq_filter}" '[.[] | select((.id | tostring) as $id | $seen | index($id) | not)]')
    fi

    inline_count=$(echo "${INLINE_JSON}" | jq 'length')
    review_count=$(echo "${REVIEWS_JSON}" | jq '[.[] | select(.state != "APPROVED" and .state != "PENDING")] | length')
    issue_comment_count=$(echo "${ISSUE_COMMENTS_JSON}" | jq 'length')
    comment_total=$(( inline_count + review_count + issue_comment_count ))

    # --- Check CI status ---
    checks_json=$(gh pr checks "${PR_NUM}" --repo "${UPSTREAM_REPO}" --json name,state 2>/dev/null || echo "[]")
    failing_checks=$(echo "${checks_json}" | jq '[.[] | select(.state == "FAIL" or .state == "FAILURE" or .state == "fail" or .state == "failure")]')
    failing_count=$(echo "${failing_checks}" | jq 'length')
    current_failing_names=$(echo "${failing_checks}" | jq -r '.[].name' 2>/dev/null | sort | tr '\n' ' ' | xargs)

    has_new_failures=false
    if [[ "${failing_count}" -gt 0 && "${current_failing_names}" != "${LAST_FAILING_NAMES}" ]]; then
        has_new_failures=true
    fi

    echo "Found ${comment_total} new comment(s)/review(s) from trusted users (${inline_count} inline, ${review_count} reviews, ${issue_comment_count} PR comments). ${failing_count} failing CI check(s)."

    has_work=false
    [[ "${comment_total}" -gt 0 ]] && has_work=true
    [[ "${has_new_failures}" == "true" ]] && has_work=true

    if [[ "${has_work}" == "true" ]]; then
        echo "Addressing feedback (comments: ${comment_total}, new CI failures: ${has_new_failures})..."
        idle_streak=0

        # Format comments for Claude
        # shellcheck disable=SC2034
        INLINE_BODY=$(echo "${INLINE_JSON}" | jq -r '.[] | "**\(.user.login)** on `\(.path // "general")`:\n\(.body)\n---"' 2>/dev/null || echo "")
        # shellcheck disable=SC2034
        REVIEW_SUMMARY=$(echo "${REVIEWS_JSON}" | jq -r '.[] | select(.state != "APPROVED" and .state != "PENDING") | "**\(.user.login)** (\(.state)):\n\(.body)\n---"' 2>/dev/null || echo "")
        # shellcheck disable=SC2034
        PR_COMMENTS_BODY=$(echo "${ISSUE_COMMENTS_JSON}" | jq -r '.[] | "**\(.user.login)**:\n\(.body)\n---"' 2>/dev/null || echo "")
        # shellcheck disable=SC2034
        FAILING_CHECKS_BODY=""
        if [[ "${has_new_failures}" == "true" ]]; then
            FAILING_CHECKS_BODY=$(echo "${failing_checks}" | jq -r '.[] | "- \(.name) (\(.state))"' 2>/dev/null || echo "")
        fi

        timeout 1800 claude \
            --model "${CLAUDE_MODEL}" \
            --allowedTools "${ALLOWED_TOOLS}" \
            --output-format stream-json \
            --max-turns 50 \
            --append-system-prompt-file "/workspace/.apm/prompts/agentic-followup.prompt.md" \
            -p "Address the review comments and fix any failing CI checks for ${JIRA_ISSUE_KEY}. The PR is #${PR_NUM} on ${UPSTREAM_REPO}.

Inline review comments:
${INLINE_BODY}

Reviews:
${REVIEW_SUMMARY}

PR conversation comments:
${PR_COMMENTS_BODY}

Failing CI checks:
${FAILING_CHECKS_BODY}" \
            --verbose 2>&1 | tee -a /workspace/artifacts/claude-output.log || true

        # Track processed comment IDs
        new_inline_ids=$(echo "${INLINE_JSON}" | jq -r '.[].id' 2>/dev/null)
        new_review_ids=$(echo "${REVIEWS_JSON}" | jq -r '.[].id' 2>/dev/null)
        new_issue_comment_ids=$(echo "${ISSUE_COMMENTS_JSON}" | jq -r '.[].id' 2>/dev/null)
        PROCESSED_IDS="${PROCESSED_IDS} ${new_inline_ids} ${new_review_ids} ${new_issue_comment_ids}"
    else
        idle_streak=$(( idle_streak + 1 ))
        echo "Nothing to do (idle streak: ${idle_streak}/3)."
    fi

    LAST_FAILING_NAMES="${current_failing_names}"

    # Exit when we've done at least 6 iterations AND had 3 consecutive idle iterations
    if [[ "${iteration}" -ge 6 && "${idle_streak}" -ge 3 ]]; then
        echo "Minimum iterations reached and no activity for 3 consecutive checks. Exiting."
        break
    fi
done

echo "=== TRT Review Responder Complete ==="
