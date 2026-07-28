#!/bin/bash
set -euo pipefail

cat > "${SHARED_DIR}/jira-helpers.sh" << 'HEREDOC_EOF'
#!/bin/bash
# Jira API and credential helper functions for jira-agent.
#
# Usage:
#   source "${SHARED_DIR}/jira-helpers.sh"
#
# Functions:
#   curl_with_retry          - Retry curl with exponential backoff on 429/5xx
#   load_jira_credentials    - Load Jira email + API token, set JIRA_AUTH
#   load_slack_credentials   - Load Slack webhook URL
#   load_github_slack_map    - Load GitHub-to-Slack user ID mapping
#   transition_issue         - Transition a Jira issue to a target status
#   set_assignee             - Set assignee on a Jira issue
#   query_jira_issues        - Query Jira for issues matching JQL
#   postprocess_jira_issue   - Label, transition, and assign after processing

JIRA_CREDS_DIR="/var/run/claude-code-service-account"

# Retry a curl command with exponential backoff on transient failures (429/5xx).
# Also validates that successful responses contain valid JSON.
# Usage: curl_with_retry [curl args...]
# Returns: sets CURL_BODY and CURL_HTTP_CODE
curl_with_retry() {
  local max_retries=3 retry_delay=5
  for attempt in $(seq 1 "$max_retries"); do
    local response curl_rc=0
    response=$(curl -s --connect-timeout 10 --max-time 30 -w "\n%{http_code}" "$@") || curl_rc=$?
    if [ "$curl_rc" -ne 0 ]; then
      CURL_HTTP_CODE="000"
      CURL_BODY=""
      echo "Warning: curl failed (exit $curl_rc, attempt $attempt/$max_retries), retrying in ${retry_delay}s..."
      sleep "$retry_delay"
      retry_delay=$((retry_delay * 2))
      continue
    fi
    CURL_HTTP_CODE=$(echo "$response" | tail -1)
    CURL_BODY=$(echo "$response" | sed '$d')

    if [ "$CURL_HTTP_CODE" = "200" ]; then
      if ! echo "$CURL_BODY" | jq empty 2>/dev/null; then
        echo "Warning: Got HTTP 200 but non-JSON response (attempt $attempt/$max_retries), retrying in ${retry_delay}s..."
        sleep "$retry_delay"
        retry_delay=$((retry_delay * 2))
        continue
      fi
      return 0
    fi
    if [ "$CURL_HTTP_CODE" = "429" ] || [ "$CURL_HTTP_CODE" -ge 500 ] 2>/dev/null; then
      echo "Warning: API returned HTTP $CURL_HTTP_CODE (attempt $attempt/$max_retries), retrying in ${retry_delay}s..."
      sleep "$retry_delay"
      retry_delay=$((retry_delay * 2))
      continue
    fi
    return 1
  done
  return 1
}

# Load Jira API credentials (Basic Auth: email:api-token).
# Sets: JIRA_TOKEN, JIRA_EMAIL, JIRA_AUTH
load_jira_credentials() {
  local token_file="${JIRA_CREDS_DIR}/jira-pat"
  local email_file="${JIRA_CREDS_DIR}/jira-email"
  [[ $- == *x* ]] && local _was_tracing=true || local _was_tracing=false
  set +x
  if [ -f "$token_file" ] && [ -f "$email_file" ]; then
    JIRA_TOKEN=$(cat "$token_file")
    JIRA_EMAIL=$(cat "$email_file")
    JIRA_AUTH=$(echo -n "${JIRA_EMAIL}:${JIRA_TOKEN}" | base64 | tr -d '\n')
    echo "Jira API credentials loaded (email + token)"
  else
    echo "Warning: Jira credentials not found (need both jira-pat and jira-email)"
    echo "Labels will not be added to processed issues"
    JIRA_TOKEN=""
    JIRA_AUTH=""
  fi
  $_was_tracing && set -x || true
}

# Load Slack webhook URL for notifications.
# Sets: SLACK_WEBHOOK_URL (exported)
load_slack_credentials() {
  local webhook_file="${JIRA_CREDS_DIR}/slack-webhook-url"
  [[ $- == *x* ]] && local _was_tracing=true || local _was_tracing=false
  set +x
  if [ -f "$webhook_file" ]; then
    export SLACK_WEBHOOK_URL
    SLACK_WEBHOOK_URL=$(cat "$webhook_file")
    echo "Slack webhook URL loaded"
  else
    echo "Warning: Slack webhook URL not found at $webhook_file"
    echo "Slack notifications will be skipped"
    export SLACK_WEBHOOK_URL=""
  fi
  $_was_tracing && set -x || true
}

# Load GitHub-to-Slack user ID mapping JSON.
# Sets: GITHUB_SLACK_MAP (exported)
load_github_slack_map() {
  local map_file="${JIRA_CREDS_DIR}/gh-to-slack-ids"
  if [ -f "$map_file" ]; then
    if GITHUB_SLACK_MAP=$(jq -c . < "$map_file" 2>/dev/null); then
      echo "GitHub-to-Slack mapping loaded"
    else
      echo "Warning: GitHub-to-Slack mapping is invalid JSON"
      echo "Reviewer pings will use GitHub usernames instead of Slack mentions"
      GITHUB_SLACK_MAP="{}"
    fi
    export GITHUB_SLACK_MAP
  else
    echo "Warning: GitHub-to-Slack mapping not found at $map_file"
    echo "Reviewer pings will use GitHub usernames instead of Slack mentions"
    export GITHUB_SLACK_MAP="{}"
  fi
}

# Transition a Jira issue to a target status.
# Usage: transition_issue <issue_key> <target_status>
# Requires: JIRA_BASE_URL, JIRA_AUTH
transition_issue() {
  local issue_key=$1 target_status=$2

  local transition_id
  if ! curl_with_retry \
    "${JIRA_BASE_URL}/rest/api/3/issue/${issue_key}/transitions" \
    -H "Authorization: Basic $JIRA_AUTH" \
    -H "Content-Type: application/json"; then
    echo "   Warning: Jira transitions API returned HTTP $CURL_HTTP_CODE"
    return 1
  fi

  transition_id=$(echo "$CURL_BODY" | jq -r --arg status "$target_status" \
    '.transitions[] | select(.name == $status) | .id' | head -1)

  if [ -n "$transition_id" ] && [ "$transition_id" != "null" ]; then
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      "${JIRA_BASE_URL}/rest/api/3/issue/${issue_key}/transitions" \
      -H "Authorization: Basic $JIRA_AUTH" \
      -H "Content-Type: application/json" \
      -d "{\"transition\":{\"id\":\"${transition_id}\"}}")
    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
      return 0
    fi
    echo "   Warning: Jira transition API returned HTTP $http_code"
    return 1
  else
    echo "   Warning: Transition to '$target_status' not available"
    return 1
  fi
}

# Set assignee on a Jira issue by account ID.
# Usage: set_assignee <issue_key> <account_id>
# Requires: JIRA_BASE_URL, JIRA_AUTH
set_assignee() {
  local issue_key=$1 account_id=$2
  curl -s -w "\n%{http_code}" -X PUT \
    "${JIRA_BASE_URL}/rest/api/3/issue/${issue_key}/assignee" \
    -H "Authorization: Basic $JIRA_AUTH" \
    -H "Content-Type: application/json" \
    -d "{\"accountId\":\"${account_id}\"}"
}

# Query Jira for issues matching JQL or a specific issue key.
# Sets: ISSUES (multi-line "KEY SUMMARY" pairs)
# Requires: JIRA_AGENT_ISSUE_KEY or JIRA_AGENT_JQL, MAX_ISSUES, JIRA_BASE_URL, JIRA_AUTH
query_jira_issues() {
  local jql search_payload search_body total_results

  echo "Querying Jira for issues..."
  if [ -n "${JIRA_AGENT_ISSUE_KEY:-}" ]; then
    echo "Using override: JIRA_AGENT_ISSUE_KEY=$JIRA_AGENT_ISSUE_KEY"
    jql="key = ${JIRA_AGENT_ISSUE_KEY}"
  else
    jql="$JIRA_AGENT_JQL"
  fi

  search_payload=$(jq -n --arg jql "$jql" --argjson max "$MAX_ISSUES" \
    '{jql: $jql, fields: ["key", "summary"], maxResults: $max}')

  if ! curl_with_retry "${JIRA_BASE_URL}/rest/api/3/search/jql" \
    -X POST \
    -H "Authorization: Basic $JIRA_AUTH" \
    -H "Content-Type: application/json" \
    -d "$search_payload"; then
    echo "ERROR: Jira search failed (HTTP $CURL_HTTP_CODE)"
    echo "Response: $CURL_BODY"
    exit 1
  fi
  search_body="$CURL_BODY"

  total_results=$(echo "$search_body" | jq -r '.total // 0')
  echo "Jira search returned $total_results result(s)"
  ISSUES=$(echo "$search_body" | jq -r '.issues[]? | "\(.key) \(.fields.summary)"')

  if [ -z "$ISSUES" ]; then
    echo "No issues found matching criteria"
    exit 0
  fi

  echo "Found issues:"
  echo "$ISSUES" | awk '{print "  - " $1}'
}

# Post-process a Jira issue: add label, transition status, set assignee.
# Usage: postprocess_jira_issue <issue_key> [success]
#   success: "true" or "false" (default: "true")
# Requires: JIRA_AUTH, JIRA_BASE_URL, JIRA_AGENT_TARGET_STATUS, JIRA_AGENT_ASSIGNEE
postprocess_jira_issue() {
  local issue_key=$1
  local success="${2:-true}"

  if [ "$success" != "true" ] || [ -z "$JIRA_AUTH" ]; then
    return 0
  fi

  echo "Adding 'agent-processed' label to $issue_key..."
  local label_response http_code
  label_response=$(curl -s -w "\n%{http_code}" -X PUT \
    "${JIRA_BASE_URL}/rest/api/3/issue/${issue_key}" \
    -H "Authorization: Basic $JIRA_AUTH" \
    -H "Content-Type: application/json" \
    -d '{"update":{"labels":[{"add":"agent-processed"}]}}')
  http_code=$(echo "$label_response" | tail -1)
  if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
    echo "   Label added successfully"
  else
    echo "   Warning: Failed to add label (HTTP $http_code)"
  fi

  if [ -n "${JIRA_AGENT_TARGET_STATUS:-}" ]; then
    local project_prefix target_status
    project_prefix=$(echo "$issue_key" | cut -d'-' -f1)
    target_status=$(echo "$JIRA_AGENT_TARGET_STATUS" | jq -r --arg prefix "$project_prefix" '.[$prefix] // empty')
    if [ -n "$target_status" ]; then
      echo "Transitioning $issue_key to '$target_status'..."
      if transition_issue "$issue_key" "$target_status"; then
        echo "   Transition successful"
      else
        echo "   Transition failed or not available"
      fi
    fi
  fi

  if [ -n "${JIRA_AGENT_ASSIGNEE:-}" ]; then
    echo "Looking up accountId for '${JIRA_AGENT_ASSIGNEE}'..."
    local assignee_account_id assignee_response
    if ! curl_with_retry -G \
      "${JIRA_BASE_URL}/rest/api/3/user/search" \
      -H "Authorization: Basic $JIRA_AUTH" \
      --data-urlencode "query=${JIRA_AGENT_ASSIGNEE}"; then
      echo "   Warning: Jira user search API returned HTTP $CURL_HTTP_CODE, skipping assignee"
      return 0
    fi
    assignee_account_id=$(echo "$CURL_BODY" \
      | jq -r --arg name "$JIRA_AGENT_ASSIGNEE" '[.[] | select(.displayName | test($name; "i"))] | .[0].accountId // empty')
    if [ -z "$assignee_account_id" ]; then
      assignee_account_id=$(echo "$CURL_BODY" | jq -r '.[0].accountId // empty')
    fi
    if [ -z "$assignee_account_id" ]; then
      echo "   Warning: No Jira user found for '${JIRA_AGENT_ASSIGNEE}', skipping assignee"
      return 0
    fi
    echo "Setting assignee to account ID '${assignee_account_id}'..."
    assignee_response=$(set_assignee "$issue_key" "$assignee_account_id")
    http_code=$(echo "$assignee_response" | tail -1)
    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
      echo "   Assignee set successfully"
    else
      echo "   Warning: Failed to set assignee (HTTP $http_code)"
    fi
  fi
}
# Record a processed issue result to the state file.
# Usage: record_issue_result <issue_key> <timestamp> <pr_url> <status>
#   status: "SUCCESS" or "FAILED"
# Requires: STATE_FILE
record_issue_result() {
  local issue_key=$1 timestamp=$2 pr_url=$3 status=$4
  echo "${issue_key} ${timestamp} ${pr_url:--} ${status}" >> "$STATE_FILE"
}
HEREDOC_EOF

echo "jira-helpers.sh written to SHARED_DIR"
