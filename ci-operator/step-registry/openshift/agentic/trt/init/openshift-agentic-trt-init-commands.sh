#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Init ==="

# --- Gangway overrides ---
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_JIRA_ISSUE_KEY:-}" ]]; then
    echo "Applying Gangway override: JIRA_ISSUE_KEY=${MULTISTAGE_PARAM_OVERRIDE_JIRA_ISSUE_KEY}"
    JIRA_ISSUE_KEY="${MULTISTAGE_PARAM_OVERRIDE_JIRA_ISSUE_KEY}"
fi
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_PLANNING_ISSUE_KEY:-}" ]]; then
    echo "Applying Gangway override: PLANNING_ISSUE_KEY=${MULTISTAGE_PARAM_OVERRIDE_PLANNING_ISSUE_KEY}"
    PLANNING_ISSUE_KEY="${MULTISTAGE_PARAM_OVERRIDE_PLANNING_ISSUE_KEY}"
fi

[[ -n "${JIRA_ISSUE_KEY:-}" ]] || { echo "ERROR: JIRA_ISSUE_KEY is required."; exit 1; }
[[ -n "${UPSTREAM_REPO:-}" ]] || { echo "ERROR: UPSTREAM_REPO is required."; exit 1; }
[[ -n "${FORK_REPO:-}" ]] || { echo "ERROR: FORK_REPO is required."; exit 1; }

echo "Issue: ${JIRA_ISSUE_KEY} | Upstream: ${UPSTREAM_REPO} | Fork: ${FORK_REPO}"

# --- Validate GitHub tokens from github-app-auth step ---
for f in gh-fork-token gh-upstream-token github-app-auth.sh github-app-token-outputs; do
    [[ -f "${SHARED_DIR}/${f}" ]] || { echo "ERROR: ${f} not found in SHARED_DIR. Run trt-github-app-auth step first."; exit 1; }
done
echo "GitHub tokens validated."

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

# --- Optionally fetch planning subtask ---
if [[ -n "${PLANNING_ISSUE_KEY:-}" ]]; then
    echo "Planning subtask: ${PLANNING_ISSUE_KEY}"
    echo "${PLANNING_ISSUE_KEY}" > "${SHARED_DIR}/planning-issue-key"

    echo "Fetching planning subtask details from Jira..."
    curl -sf --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 5 \
        "https://redhat.atlassian.net/rest/api/2/issue/${PLANNING_ISSUE_KEY}?fields=summary,description,status,labels,comment,issuetype,priority" \
        > "${SHARED_DIR}/planning-issue.json" || {
        echo "ERROR: Failed to fetch planning subtask ${PLANNING_ISSUE_KEY} from Jira."; exit 1;
    }

    echo "Planning summary: $(jq -r '.fields.summary // "No summary"' "${SHARED_DIR}/planning-issue.json")"
fi

echo "=== TRT Init Complete ==="
