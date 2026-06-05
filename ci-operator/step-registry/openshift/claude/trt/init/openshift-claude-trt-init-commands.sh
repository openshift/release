#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Init ==="

# --- Gangway override ---
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_JIRA_ISSUE_KEY:-}" ]]; then
    echo "Applying Gangway override: JIRA_ISSUE_KEY=${MULTISTAGE_PARAM_OVERRIDE_JIRA_ISSUE_KEY}"
    JIRA_ISSUE_KEY="${MULTISTAGE_PARAM_OVERRIDE_JIRA_ISSUE_KEY}"
fi

[[ -n "${JIRA_ISSUE_KEY:-}" ]] || { echo "ERROR: JIRA_ISSUE_KEY is required."; exit 1; }
[[ -n "${UPSTREAM_REPO:-}" ]] || { echo "ERROR: UPSTREAM_REPO is required."; exit 1; }
[[ -n "${FORK_REPO:-}" ]] || { echo "ERROR: FORK_REPO is required."; exit 1; }

echo "Issue: ${JIRA_ISSUE_KEY} | Upstream: ${UPSTREAM_REPO} | Fork: ${FORK_REPO}"

# --- Validate credentials ---
GH_APP_DIR="/var/run/github-token"
for f in app-id installation-id openshift-installation-id private-key; do
    [[ -f "${GH_APP_DIR}/${f}" ]] || { echo "ERROR: GitHub App credential ${f} not found."; exit 1; }
done
echo "GitHub App credentials validated."

# --- Persist issue key for subsequent steps ---
echo "${JIRA_ISSUE_KEY}" > "${SHARED_DIR}/jira-issue-key"

# --- Fetch Jira issue ---
echo "Fetching issue details from Jira..."
curl -sf --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 5 \
    "https://redhat.atlassian.net/rest/api/2/issue/${JIRA_ISSUE_KEY}?fields=summary,description,status,labels,comment,issuetype,priority" \
    > "${SHARED_DIR}/jira-issue.json" || {
    echo "ERROR: Failed to fetch issue ${JIRA_ISSUE_KEY} from Jira."; exit 1;
}

ISSUE_SUMMARY=$(jq -r '.fields.summary // "No summary"' "${SHARED_DIR}/jira-issue.json")
echo "Summary: ${ISSUE_SUMMARY}"

# --- Write common shell library for subsequent steps ---
cat > "${SHARED_DIR}/trt-common.sh" <<'COMMON_EOF'
# Common functions for TRT agentic workflows.
# Source this from SHARED_DIR in any step: source "${SHARED_DIR}/trt-common.sh"

GH_APP_DIR="/var/run/github-token"
TRUSTED_BOTS="coderabbitai"

_generate_token_for_installation() {
    local installation_id=$1
    set +x
    local app_id private_key_file
    app_id=$(cat "${GH_APP_DIR}/app-id")
    private_key_file="${GH_APP_DIR}/private-key"

    local now iat exp header payload signature jwt
    now=$(date +%s)
    iat=$((now - 60))
    exp=$((now + 600))

    header=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    payload=$(echo -n "{\"iat\":${iat},\"exp\":${exp},\"iss\":\"${app_id}\"}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    signature=$(echo -n "${header}.${payload}" | openssl dgst -sha256 -sign "${private_key_file}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    jwt="${header}.${payload}.${signature}"

    curl -sf -X POST \
        -H "Authorization: Bearer ${jwt}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations/${installation_id}/access_tokens" \
        | jq -r '.token'
}

generate_github_tokens() {
    set +x
    local fork_id upstream_id token

    fork_id=$(cat "${GH_APP_DIR}/installation-id")
    token=$(_generate_token_for_installation "${fork_id}")
    if [[ -z "${token}" || "${token}" == "null" ]]; then
        echo "ERROR: Failed to generate fork token."; return 1
    fi
    export GH_FORK_TOKEN="${token}"

    upstream_id=$(cat "${GH_APP_DIR}/openshift-installation-id")
    token=$(_generate_token_for_installation "${upstream_id}")
    if [[ -z "${token}" || "${token}" == "null" ]]; then
        echo "ERROR: Failed to generate upstream token."; return 1
    fi
    export GITHUB_TOKEN="${token}"

    git config --global credential.helper '!f() { echo username=x-access-token; echo "password=${GH_FORK_TOKEN}"; }; f'
    echo "GitHub tokens generated (fork: push, upstream: gh CLI)."
}

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

fetch_trusted_review_comments() {
    local pr_num=$1 upstream_repo=$2
    local raw_comments raw_reviews

    raw_comments=$(gh api "repos/${upstream_repo}/pulls/${pr_num}/comments" --paginate 2>/dev/null || echo "[]")
    raw_reviews=$(gh api "repos/${upstream_repo}/pulls/${pr_num}/reviews" --paginate 2>/dev/null || echo "[]")

    local all_users trusted_users=""
    all_users=$(echo "${raw_comments}" "${raw_reviews}" | jq -r '.[].user.login' 2>/dev/null | sort -u)
    for user in ${all_users}; do
        if is_trusted_user "${user}"; then
            trusted_users="${trusted_users} ${user}"
        fi
    done

    local trusted_jq_filter
    trusted_jq_filter=$(echo "${trusted_users}" | xargs -n1 | jq -R . | jq -s '.')
    COMMENTS_JSON=$(echo "${raw_comments}" | jq --argjson trusted "${trusted_jq_filter}" '[.[] | select(.user.login as $u | $trusted | index($u))]')
    REVIEWS_JSON=$(echo "${raw_reviews}" | jq --argjson trusted "${trusted_jq_filter}" '[.[] | select(.user.login as $u | $trusted | index($u))]')

    local comment_count review_count
    comment_count=$(echo "${COMMENTS_JSON}" | jq 'length')
    review_count=$(echo "${REVIEWS_JSON}" | jq '[.[] | select(.state != "APPROVED" and .state != "PENDING")] | length')

    export REVIEW_BODY=$(echo "${COMMENTS_JSON}" | jq -r '.[] | "**\(.user.login)** on `\(.path // "general")`:\n\(.body)\n---"' 2>/dev/null || echo "No inline comments.")
    export REVIEW_SUMMARY=$(echo "${REVIEWS_JSON}" | jq -r '.[] | select(.state != "APPROVED" and .state != "PENDING") | "**\(.user.login)** (\(.state)):\n\(.body)\n---"' 2>/dev/null || echo "No reviews.")

    echo "Found ${comment_count} inline comment(s) and ${review_count} review(s) from trusted users."
    return $(( comment_count + review_count ))
}

load_jira_issue() {
    local issue_file="${SHARED_DIR}/jira-issue.json"
    [[ -f "${issue_file}" ]] || { echo "ERROR: Jira issue not found in SHARED_DIR."; return 1; }
    export JIRA_ISSUE_KEY=$(cat "${SHARED_DIR}/jira-issue-key")
    export ISSUE_SUMMARY=$(jq -r '.fields.summary // "No summary"' "${issue_file}")
    export ISSUE_DESCRIPTION=$(jq -r '.fields.description // "No description"' "${issue_file}")
    export ISSUE_TYPE=$(jq -r '.fields.issuetype.name // "Unknown"' "${issue_file}")
    export ISSUE_STATUS=$(jq -r '.fields.status.name // "Unknown"' "${issue_file}")
    export ISSUE_COMMENTS=$(jq -r '[.fields.comment.comments[]? | "\(.author.displayName) (\(.created)): \(.body)"] | join("\n---\n")' "${issue_file}" 2>/dev/null || echo "No comments")
}

setup_workspace() {
    cd /workspace
    git config user.name "openshift-trt"
    git config user.email "openshift-trt@redhat.com"
    git remote add fork "https://github.com/${FORK_REPO}.git"
    echo "Running setup script: ${SETUP_SCRIPT}..."
    source "/workspace/${SETUP_SCRIPT}"
    mkdir -p /workspace/artifacts
}

setup_artifact_trap() {
    copy_artifacts() {
        echo "Copying artifacts..."
        cp /workspace/artifacts/* "${ARTIFACT_DIR}/" 2>/dev/null || true
        podman logs sippy-postgres > "${ARTIFACT_DIR}/postgres.log" 2>&1 || true
    }
    trap copy_artifacts EXIT TERM INT
}
COMMON_EOF

echo "=== TRT Init Complete ==="
