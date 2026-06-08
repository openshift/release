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

# --- Validate GitHub App credentials ---
GH_APP_DIR="/var/run/github-token"
for f in app-id installation-id openshift-installation-id private-key; do
    [[ -f "${GH_APP_DIR}/${f}" ]] || { echo "ERROR: GitHub App credential ${f} not found."; exit 1; }
done

# --- Generate tokens ---
set +x
APP_ID=$(cat "${GH_APP_DIR}/app-id")
PRIVATE_KEY="${GH_APP_DIR}/private-key"

generate_token() {
    local installation_id=$1
    local now iat exp header payload signature jwt
    now=$(date +%s)
    iat=$((now - 60))
    exp=$((now + 600))
    header=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    payload=$(echo -n "{\"iat\":${iat},\"exp\":${exp},\"iss\":\"${APP_ID}\"}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    signature=$(echo -n "${header}.${payload}" | openssl dgst -sha256 -sign "${PRIVATE_KEY}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    jwt="${header}.${payload}.${signature}"
    curl -sf -X POST \
        -H "Authorization: Bearer ${jwt}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations/${installation_id}/access_tokens" \
        | jq -r '.token'
}

FORK_TOKEN=$(generate_token "$(cat "${GH_APP_DIR}/installation-id")")
[[ -n "${FORK_TOKEN}" && "${FORK_TOKEN}" != "null" ]] || { echo "ERROR: Failed to generate fork token."; exit 1; }

UPSTREAM_TOKEN=$(generate_token "$(cat "${GH_APP_DIR}/openshift-installation-id")")
[[ -n "${UPSTREAM_TOKEN}" && "${UPSTREAM_TOKEN}" != "null" ]] || { echo "ERROR: Failed to generate upstream token."; exit 1; }

echo "${FORK_TOKEN}" > "${SHARED_DIR}/gh-fork-token"
echo "${UPSTREAM_TOKEN}" > "${SHARED_DIR}/gh-upstream-token"
echo "GitHub tokens generated."

# --- Persist issue key ---
echo "${JIRA_ISSUE_KEY}" > "${SHARED_DIR}/jira-issue-key"

# --- Fetch Jira issue ---
echo "Fetching issue details from Jira..."
curl -sf --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 5 \
    "https://redhat.atlassian.net/rest/api/2/issue/${JIRA_ISSUE_KEY}?fields=summary,description,status,labels,comment,issuetype,priority" \
    > "${SHARED_DIR}/jira-issue.json" || {
    echo "ERROR: Failed to fetch issue ${JIRA_ISSUE_KEY} from Jira."; exit 1;
}

echo "Summary: $(jq -r '.fields.summary // "No summary"' "${SHARED_DIR}/jira-issue.json")"
echo "=== TRT Init Complete ==="
