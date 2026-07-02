#!/bin/bash
set -euo pipefail

echo "=== HyperShift Jira Agent Process ==="

# Apply Gangway API overrides (MULTISTAGE_PARAM_OVERRIDE_* prefix)
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_JIRA_AGENT_ISSUE_KEY:-}" ]]; then
  echo "Applying Gangway override: JIRA_AGENT_ISSUE_KEY=${MULTISTAGE_PARAM_OVERRIDE_JIRA_AGENT_ISSUE_KEY}"
  export JIRA_AGENT_ISSUE_KEY="${MULTISTAGE_PARAM_OVERRIDE_JIRA_AGENT_ISSUE_KEY}"
fi

# State file for sharing results with report step
STATE_FILE="${SHARED_DIR}/processed-issues.txt"

# Clone HyperShift fork (we push here and create PRs to upstream)
echo "Cloning HyperShift repository..."
git clone https://github.com/hypershift-community/hypershift /tmp/hypershift

# Install tool dependencies
echo "Installing tool dependencies..."
GOFLAGS="" go install golang.org/x/tools/gopls@v0.21.0
python3.9 -m ensurepip --user 2>/dev/null || true
python3.9 -m pip install --user pre-commit 2>&1 | tail -1
export PATH="${GOPATH:-$HOME/go}/bin:$HOME/.local/bin:$PATH"

# Force HTTPS for all github.com git operations (plugin install defaults to SSH which lacks host keys in CI)
git config --global url."https://github.com/".insteadOf "git@github.com:"

# Install the openshift-developer plugin (bundles jira, ci, golang, prodsec-skills, git)
echo "Installing Claude Code plugins..."
claude plugin marketplace add openshift-eng/ai-helpers
claude plugin marketplace add RedHatProductSecurity/prodsec-skills
claude plugin install openshift-developer@ai-helpers
claude plugin install prow-agent@ai-helpers

cd /tmp/hypershift

# Configure git
git config user.name "OpenShift CI Bot"
git config user.email "ci-bot@redhat.com"

# Sync fork with upstream before doing any work
echo "Syncing fork with upstream openshift/hypershift..."
git remote add upstream https://github.com/openshift/hypershift.git
git fetch upstream main
git checkout main
git rebase upstream/main
echo "Fork synced with upstream successfully"

# Generate GitHub App installation token
echo "Generating GitHub App token..."

GITHUB_APP_CREDS_DIR="/var/run/claude-code-service-account"
APP_ID_FILE="${GITHUB_APP_CREDS_DIR}/app-id"
INSTALLATION_ID_FILE="${GITHUB_APP_CREDS_DIR}/installation-id"
PRIVATE_KEY_FILE="${GITHUB_APP_CREDS_DIR}/private-key"

# Check if all required credentials exist
INSTALLATION_ID_UPSTREAM_FILE="${GITHUB_APP_CREDS_DIR}/o-h-installation-id"

if [ ! -f "$APP_ID_FILE" ] || [ ! -f "$INSTALLATION_ID_FILE" ] || [ ! -f "$PRIVATE_KEY_FILE" ] || [ ! -f "$INSTALLATION_ID_UPSTREAM_FILE" ]; then
  echo "GitHub App credentials not yet available in ${GITHUB_APP_CREDS_DIR}"
  echo "Available files:"
  ls -la "${GITHUB_APP_CREDS_DIR}/" || echo "Directory does not exist"
  echo ""
  echo "Waiting for Vault secretsync to complete. The following keys are required:"
  echo "  - app-id"
  echo "  - installation-id (for hypershift-community fork)"
  echo "  - o-h-installation-id (for openshift/hypershift upstream)"
  echo "  - private-key"
  echo ""
  echo "Exiting gracefully. Re-run once secrets are synced."
  exit 0
fi

APP_ID=$(cat "$APP_ID_FILE")
INSTALLATION_ID_FORK=$(cat "$INSTALLATION_ID_FILE")
INSTALLATION_ID_UPSTREAM=$(cat "$INSTALLATION_ID_UPSTREAM_FILE")

# Function to generate GitHub App token for a given installation ID
generate_github_token() {
  local INSTALL_ID=$1
  local NOW
  NOW=$(date +%s)
  local IAT=$((NOW - 60))
  local EXP=$((NOW + 600))

  local HEADER
  HEADER=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
  local PAYLOAD
  PAYLOAD=$(echo -n "{\"iat\":${IAT},\"exp\":${EXP},\"iss\":\"${APP_ID}\"}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
  local SIGNATURE
  SIGNATURE=$(echo -n "${HEADER}.${PAYLOAD}" | openssl dgst -sha256 -sign "$PRIVATE_KEY_FILE" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
  local JWT="${HEADER}.${PAYLOAD}.${SIGNATURE}"

  curl -s -X POST \
    -H "Authorization: Bearer ${JWT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${INSTALL_ID}/access_tokens" \
    | jq -r '.token'
}

# Generate token for fork (hypershift-community/hypershift) - for pushing branches
echo "Generating GitHub App token for fork..."
GITHUB_TOKEN_FORK=$(generate_github_token "$INSTALLATION_ID_FORK")
if [ -z "$GITHUB_TOKEN_FORK" ] || [ "$GITHUB_TOKEN_FORK" = "null" ]; then
  echo "ERROR: Failed to generate GitHub App token for fork"
  exit 1
fi
echo "Fork token generated successfully"

# Generate token for upstream (openshift/hypershift) - for creating PRs
echo "Generating GitHub App token for upstream..."
GITHUB_TOKEN_UPSTREAM=$(generate_github_token "$INSTALLATION_ID_UPSTREAM")
if [ -z "$GITHUB_TOKEN_UPSTREAM" ] || [ "$GITHUB_TOKEN_UPSTREAM" = "null" ]; then
  echo "ERROR: Failed to generate GitHub App token for upstream"
  exit 1
fi
echo "Upstream token generated successfully"

# Configure git to use the fork token for push operations via credential helper
# Using credential helper instead of URL rewriting prevents token leaking in git remote output
git config --global credential.helper "!f() { echo username=x-access-token; echo password=${GITHUB_TOKEN_FORK}; }; f"

# Export upstream token as GITHUB_TOKEN for gh CLI (used for PR creation)
export GITHUB_TOKEN="$GITHUB_TOKEN_UPSTREAM"
echo "GitHub App tokens configured successfully"

# Configuration: maximum issues to process per run (default: 1)
MAX_ISSUES=${JIRA_AGENT_MAX_ISSUES:-1}
echo "Configuration: MAX_ISSUES=$MAX_ISSUES"

# Shared prompt instruction for subagent behavior
SUBAGENT_PROMPT="SUBAGENTS: Launch ALL subagents in parallel (single message with multiple Task tool calls) for maximum speed. Each subagent should be given subagent_type: \"general-purpose\". Do NOT set the model parameter — let subagents inherit the parent model, as these analysis tasks require a capable model."

# Security prompt appended to all Claude invocations
SECURITY_PROMPT="SECURITY: Do NOT run commands that reveal git credentials like 'git remote -v' or 'git remote get-url origin'."

# Load Jira API credentials for Atlassian Cloud (Basic Auth: email:api-token)
JIRA_TOKEN_FILE="/var/run/claude-code-service-account/jira-pat"
JIRA_EMAIL_FILE="/var/run/claude-code-service-account/jira-email"
if [ -f "$JIRA_TOKEN_FILE" ] && [ -f "$JIRA_EMAIL_FILE" ]; then
  JIRA_TOKEN=$(cat "$JIRA_TOKEN_FILE")
  JIRA_EMAIL=$(cat "$JIRA_EMAIL_FILE")
  JIRA_AUTH=$(echo -n "${JIRA_EMAIL}:${JIRA_TOKEN}" | base64 | tr -d '\n')
  echo "Jira API credentials loaded (email + token)"
else
  echo "Warning: Jira credentials not found (need both jira-pat and jira-email)"
  echo "Labels will not be added to processed issues"
  JIRA_TOKEN=""
  JIRA_AUTH=""
fi

# Load Slack webhook URL for notifications (tracing disabled to protect credential)
SLACK_WEBHOOK_FILE="/var/run/claude-code-service-account/slack-webhook-url"
[[ $- == *x* ]] && _SLACK_WAS_TRACING=true || _SLACK_WAS_TRACING=false
set +x
if [ -f "$SLACK_WEBHOOK_FILE" ]; then
  SLACK_WEBHOOK_URL=$(cat "$SLACK_WEBHOOK_FILE")
  echo "Slack webhook URL loaded"
else
  echo "Warning: Slack webhook URL not found at $SLACK_WEBHOOK_FILE"
  echo "Slack notifications will be skipped"
  SLACK_WEBHOOK_URL=""
fi
$_SLACK_WAS_TRACING && set -x

# Load GitHub-to-Slack user ID mapping
GITHUB_SLACK_MAP_FILE="/var/run/claude-code-service-account/gh-to-slack-ids"
if [ -f "$GITHUB_SLACK_MAP_FILE" ]; then
  if GITHUB_SLACK_MAP=$(jq -c . < "$GITHUB_SLACK_MAP_FILE" 2>/dev/null); then
    echo "GitHub-to-Slack mapping loaded"
  else
    echo "Warning: GitHub-to-Slack mapping is invalid JSON"
    echo "Reviewer pings will use GitHub usernames instead of Slack mentions"
    GITHUB_SLACK_MAP="{}"
  fi
else
  echo "Warning: GitHub-to-Slack mapping not found at $GITHUB_SLACK_MAP_FILE"
  echo "Reviewer pings will use GitHub usernames instead of Slack mentions"
  GITHUB_SLACK_MAP="{}"
fi

# Extract Slack fallback user ID from mapping (pinged when no reviewers are assigned)
SLACK_FALLBACK_USER_ID=$(jq -r '.["backup-user"] // empty' <<<"$GITHUB_SLACK_MAP")
if [ -n "$SLACK_FALLBACK_USER_ID" ]; then
  echo "Slack fallback user ID loaded from mapping"
else
  echo "Warning: No 'backup-user' key in GitHub-to-Slack mapping"
fi

# Function to transition a Jira issue to a target status
transition_issue() {
  local ISSUE_KEY=$1
  local TARGET_STATUS=$2

  # Get available transitions
  TRANSITIONS=$(curl -s \
    "https://redhat.atlassian.net/rest/api/3/issue/$ISSUE_KEY/transitions" \
    -H "Authorization: Basic $JIRA_AUTH" \
    -H "Content-Type: application/json")

  # Find transition ID for target status (match by name)
  TRANSITION_ID=$(echo "$TRANSITIONS" | jq -r --arg status "$TARGET_STATUS" \
    '.transitions[] | select(.name == $status) | .id' | head -1)

  if [ -n "$TRANSITION_ID" ] && [ "$TRANSITION_ID" != "null" ]; then
    curl -s -X POST \
      "https://redhat.atlassian.net/rest/api/3/issue/$ISSUE_KEY/transitions" \
      -H "Authorization: Basic $JIRA_AUTH" \
      -H "Content-Type: application/json" \
      -d "{\"transition\":{\"id\":\"$TRANSITION_ID\"}}"
    return 0
  else
    echo "   Warning: Transition to '$TARGET_STATUS' not available"
    return 1
  fi
}

# Function to set assignee on a Jira issue (Cloud uses accountId)
set_assignee() {
  local ISSUE_KEY=$1
  local ACCOUNT_ID=$2

  curl -s -w "\n%{http_code}" -X PUT \
    "https://redhat.atlassian.net/rest/api/3/issue/$ISSUE_KEY/assignee" \
    -H "Authorization: Basic $JIRA_AUTH" \
    -H "Content-Type: application/json" \
    -d "{\"accountId\":\"$ACCOUNT_ID\"}"
}

# Function to send Slack notification after PR creation
send_slack_notification() {
  local PR_URL=$1
  local PR_NUM=$2

  if [ -z "$SLACK_WEBHOOK_URL" ]; then
    echo "   Skipping Slack notification (no webhook URL configured)"
    return 0
  fi

  echo "   Polling for PR reviewers (up to 2 minutes)..."
  local REVIEWERS=""
  local PR_TITLE=""
  local ATTEMPT=0
  local MAX_ATTEMPTS=5

  while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    local PR_DATA
    PR_DATA=$(gh pr view "$PR_NUM" --repo openshift/hypershift --json reviewRequests,title 2>/dev/null || echo "{}")
    PR_TITLE=$(echo "$PR_DATA" | jq -r '.title // empty' 2>/dev/null)
    REVIEWERS=$(echo "$PR_DATA" | jq -r '.reviewRequests[]?.login // empty' 2>/dev/null)
    if [ -n "$REVIEWERS" ]; then
      echo "   Reviewers found: $REVIEWERS"
      break
    fi
    ATTEMPT=$((ATTEMPT + 1))
    if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
      echo "   No reviewers yet, retrying in 30s (attempt $ATTEMPT/$MAX_ATTEMPTS)..."
      sleep 30
    fi
  done

  # Fallback PR title if not fetched
  if [ -z "$PR_TITLE" ]; then
    PR_TITLE="PR #${PR_NUM}"
  fi

  # Build reviewer mention string
  local REVIEWER_MENTIONS=""
  if [ -n "$REVIEWERS" ]; then
    while IFS= read -r gh_user; do
      local slack_id
      slack_id=$(echo "$GITHUB_SLACK_MAP" | jq -r --arg user "$gh_user" '.[$user] // empty' 2>/dev/null)
      if [ -n "$slack_id" ]; then
        REVIEWER_MENTIONS="${REVIEWER_MENTIONS} <@${slack_id}>"
      else
        REVIEWER_MENTIONS="${REVIEWER_MENTIONS} ${gh_user}"
      fi
    done <<< "$REVIEWERS"
  else
    echo "   No reviewers assigned after 2 minutes, using fallback"
    if [ -n "$SLACK_FALLBACK_USER_ID" ]; then
      REVIEWER_MENTIONS="<@${SLACK_FALLBACK_USER_ID}>"
    else
      REVIEWER_MENTIONS="(none assigned)"
    fi
  fi
  REVIEWER_MENTIONS=$(echo "$REVIEWER_MENTIONS" | sed 's/^ //')

  # Send Slack message (tracing disabled to protect webhook URL)
  local SLACK_PAYLOAD
  SLACK_PAYLOAD=$(jq -n --arg title "$PR_TITLE" --arg url "$PR_URL" --arg reviewers "$REVIEWER_MENTIONS" \
    '{text: ":hypershift-bot: *Jira Agent PR ready for review*\n:review: <\($url)|\($title)>\n:eyes: Reviewers: \($reviewers)"}')

  [[ $- == *x* ]] && local _was_tracing=true || local _was_tracing=false
  set +x
  set +e
  local SLACK_RESPONSE
  SLACK_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    --connect-timeout 10 \
    --max-time 20 \
    -H 'Content-type: application/json' \
    --data "$SLACK_PAYLOAD" \
    "$SLACK_WEBHOOK_URL")
  local CURL_EXIT_CODE=$?
  set -e
  $_was_tracing && set -x

  if [ $CURL_EXIT_CODE -ne 0 ]; then
    echo "   Warning: Failed to send Slack notification (curl exit $CURL_EXIT_CODE)"
    return 0
  fi

  local SLACK_HTTP_CODE
  SLACK_HTTP_CODE=$(echo "$SLACK_RESPONSE" | tail -1)

  if [ "$SLACK_HTTP_CODE" = "200" ]; then
    echo "   Slack notification sent successfully"
  else
    echo "   Warning: Failed to send Slack notification (HTTP $SLACK_HTTP_CODE)"
  fi
}

# OTEL / BigQuery telemetry support
EXTRACT_METRICS="/opt/ai-helpers/plugins/prow-agent/scripts/extract_metrics.py"
OTEL_LOG="${ARTIFACT_DIR}/claude-otel.jsonl"

# Wrapper: run claude via agentic-ci for native OTEL collection
# Uses --no-streaming so stdout passes through raw for tee/reports.
# Filters to JSON lines only (agentic-ci log lines are stripped).
# Captures OTEL JSONL per invocation and appends to the consolidated log.
run_claude() {
  local phase=$1; shift
  local issue_key=$1; shift
  local prompt="$1"; shift

  local phase_otel="/tmp/claude-${issue_key}-${phase}-otel.jsonl"

  agentic-ci run \
    --backend local \
    --harness claude-code \
    --model "${CLAUDE_MODEL}" \
    --workdir /tmp/hypershift \
    --no-streaming \
    "${prompt}" \
    -- \
    --permission-mode default \
    --verbose \
    --output-format stream-json \
    "$@" \
    | grep '^{'
  local rc=${PIPESTATUS[0]}

  # Collect OTEL JSONL from agentic-ci temp dirs into per-phase and consolidated logs
  for f in /tmp/agentic-ci-run.*/claude-otel.jsonl; do
    if [ -f "$f" ]; then
      cat "$f" >> "${phase_otel}"
      cat "$f" >> "${OTEL_LOG}"
    fi
  done
  rm -rf /tmp/agentic-ci-run.*
  return $rc
}

# Extract session metrics from OTEL data and produce BigQuery autodl
extract_session_metrics() {
  local issue_key=$1
  local phase=$2

  if [ ! -f "${EXTRACT_METRICS}" ]; then
    echo "Warning: extract_metrics.py not found, skipping session metrics"
    return 0
  fi

  local phase_otel="/tmp/claude-${issue_key}-${phase}-otel.jsonl"
  if [ ! -f "$phase_otel" ] || [ ! -s "$phase_otel" ]; then
    echo "Warning: No OTEL data for ${phase}, skipping session metrics"
    return 0
  fi

  python3 "${EXTRACT_METRICS}" "$phase_otel" \
    "${ARTIFACT_DIR}/claude-${issue_key}-${phase}-session-metrics-autodl.json" \
    2>&1 || echo "Warning: Failed to extract session metrics for ${phase}"
}

# Generate domain-specific autodl for the jira_agent BigQuery table
generate_autodl() {
  local issue_key=$1
  local phase=$2
  local result=$3
  local pr_url=${4:-}
  local session_id=${5:-}
  local analyzed_at
  analyzed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local autodl_file="${ARTIFACT_DIR}/jira-agent-${issue_key}-${phase}-autodl.json"

  jq -n \
    --arg issue_key "$issue_key" \
    --arg phase "$phase" \
    --arg result "$result" \
    --arg pr_url "$pr_url" \
    --arg session_id "$session_id" \
    --arg analyzed_at "$analyzed_at" \
    --arg job_name "${JOB_NAME:-}" \
    --arg build_id "${BUILD_ID:-}" \
    '{
      table_name: "jira_agent",
      schema: {
        session_id: "string",
        agent: "string",
        phase: "string",
        issue_key: "string",
        pr_url: "string",
        result: "string",
        analyzed_at: "string",
        job_name: "string",
        build_id: "string"
      },
      schema_mapping: null,
      rows: [{
        session_id: $session_id,
        agent: "jira-agent",
        phase: $phase,
        issue_key: $issue_key,
        pr_url: $pr_url,
        result: $result,
        analyzed_at: $analyzed_at,
        job_name: $job_name,
        build_id: $build_id
      }],
      chunk_size: 0,
      expiration_days: 0,
      partition_column: ""
    }' > "$autodl_file"
  echo "Generated autodl: ${autodl_file}"
}

# Helper: extract session_id from stream-json output
get_session_id() {
  local json_file=$1
  grep '"type":"result"' "$json_file" 2>/dev/null | head -1 | jq -r '.session_id // ""' 2>/dev/null || echo ""
}

# Helper: extract token usage from stream-json output and save to SHARED_DIR
extract_tokens() {
  local JSON_FILE=$1
  local OUTPUT_FILE=$2

  grep '"type":"result"' "$JSON_FILE" \
    | head -1 \
    | jq '{
        total_cost_usd: (.total_cost_usd // 0),
        duration_ms: (.duration_ms // 0),
        num_turns: (.num_turns // 0),
        input_tokens: (.usage.input_tokens // 0),
        output_tokens: (.usage.output_tokens // 0),
        cache_read_input_tokens: (.usage.cache_read_input_tokens // 0),
        cache_creation_input_tokens: (.usage.cache_creation_input_tokens // 0),
        model_usage: (.modelUsage // {}),
        model: ((.modelUsage // {} | keys | first) // "unknown")
      }' > "$OUTPUT_FILE" 2>/dev/null \
    || echo '{"total_cost_usd":0,"duration_ms":0,"num_turns":0,"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"model_usage":{},"model":"unknown"}' > "$OUTPUT_FILE"
}

# Helper: extract text, tool usage, and errors from stream-json output
extract_artifacts() {
  local JSON_FILE=$1
  local PREFIX=$2

  jq -j 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text // empty' "$JSON_FILE" > "${SHARED_DIR}/${PREFIX}-text.txt" 2>/dev/null || true
  jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | "\(.name): \(.input | keys | join(", "))"' "$JSON_FILE" 2>/dev/null | sort | uniq -c | sort -rn > "${SHARED_DIR}/${PREFIX}-tools.txt" 2>/dev/null || true
  jq -r 'select(.type == "user") | .tool_use_result | select(type == "string") | select(startswith("Error:")) | gsub("\n"; "⏎")' "$JSON_FILE" 2>/dev/null | sort | uniq -c | sort -rn | sed 's/⏎/\n/g' > "${SHARED_DIR}/${PREFIX}-errors.txt" 2>/dev/null || true
}

# Query Jira for issues (excluding already processed ones via label)
echo "Querying Jira for issues..."
if [ -n "${JIRA_AGENT_ISSUE_KEY:-}" ]; then
  echo "Using override: JIRA_AGENT_ISSUE_KEY=$JIRA_AGENT_ISSUE_KEY"
  JQL="key = ${JIRA_AGENT_ISSUE_KEY}"
else
  JQL='project in (OCPBUGS, CNTRLPLANE) AND resolution = Unresolved AND status in (New, "To Do") AND labels = issue-for-agent AND labels != agent-processed'
fi
SEARCH_PAYLOAD=$(jq -n --arg jql "$JQL" --argjson max "$MAX_ISSUES" \
  '{jql: $jql, fields: ["key", "summary"], maxResults: $max}')
SEARCH_RESPONSE=$(curl -s -w "\n%{http_code}" "https://redhat.atlassian.net/rest/api/3/search/jql" \
  -X POST \
  -H "Authorization: Basic $JIRA_AUTH" \
  -H "Content-Type: application/json" \
  -d "$SEARCH_PAYLOAD")
SEARCH_HTTP_CODE=$(echo "$SEARCH_RESPONSE" | tail -1)
SEARCH_BODY=$(echo "$SEARCH_RESPONSE" | sed '$d')

if [ "$SEARCH_HTTP_CODE" != "200" ]; then
  echo "ERROR: Jira search failed (HTTP $SEARCH_HTTP_CODE)"
  echo "Response: $SEARCH_BODY"
  exit 1
fi

TOTAL_RESULTS=$(echo "$SEARCH_BODY" | jq -r '.total // 0')
echo "Jira search returned $TOTAL_RESULTS result(s)"
ISSUES=$(echo "$SEARCH_BODY" | jq -r '.issues[]? | "\(.key) \(.fields.summary)"')

if [ -z "$ISSUES" ]; then
  echo "No issues found matching criteria"
  exit 0
fi

echo "Found issues:"
echo "$ISSUES" | awk '{print "  - " $1}'

# Counters for summary
PROCESSED_COUNT=0
FAILED_COUNT=0
TOTAL_PROCESSED_OR_FAILED=0

# Process each issue
while IFS= read -r line; do
  # Stop if we've reached the max issues limit (counting both successful and failed)
  if [ $TOTAL_PROCESSED_OR_FAILED -ge "$MAX_ISSUES" ]; then
    echo "Reached maximum issues limit ($MAX_ISSUES). Stopping."
    break
  fi
  # Reset to main branch for clean state between issues
  git checkout main 2>/dev/null || true
  git reset --hard upstream/main 2>/dev/null || true

  ISSUE_KEY=$(echo "$line" | awk '{print $1}')
  ISSUE_SUMMARY=$(echo "$line" | cut -d' ' -f2-)

  echo ""
  echo "=========================================="
  echo "Processing: $ISSUE_KEY"
  echo "Summary: $ISSUE_SUMMARY"
  echo "=========================================="

  TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # === Phase 1: Solve (via /jira:solve skill) ===
  echo "Phase 1: Running /jira:solve $ISSUE_KEY origin --ci"

  PHASE1_START=$(date +%s)

  FORK_CONTEXT="IMPORTANT: You are working in a fork (hypershift-community/hypershift). Git push is pre-configured to work with the fork. After creating commits on your feature branch, push the branch to origin. Do NOT create a Pull Request - the PR will be created in a subsequent automated step after code review. ${SECURITY_PROMPT} ${SUBAGENT_PROMPT}"

  set +e
  run_claude "solve" "$ISSUE_KEY" "/jira:solve $ISSUE_KEY origin --ci" \
    --append-system-prompt "$FORK_CONTEXT" \
    --allowedTools "Bash Read Write Edit Grep Glob WebFetch Agent Skill Task" \
    --max-turns 300 \
    --effort max \
    2> "/tmp/claude-${ISSUE_KEY}-output.log" \
    | tee "/tmp/claude-${ISSUE_KEY}-output.json"
  EXIT_CODE=$?
  set -e

  extract_artifacts "/tmp/claude-${ISSUE_KEY}-output.json" "claude-${ISSUE_KEY}-output"
  extract_session_metrics "$ISSUE_KEY" "solve"
  extract_tokens "/tmp/claude-${ISSUE_KEY}-output.json" "${SHARED_DIR}/claude-${ISSUE_KEY}-solve-tokens.json"
  echo "Phase 1 tokens: $(cat "${SHARED_DIR}/claude-${ISSUE_KEY}-solve-tokens.json")"
  SOLVE_SESSION_ID=$(get_session_id "/tmp/claude-${ISSUE_KEY}-output.json")
  generate_autodl "$ISSUE_KEY" "solve" "$([ $EXIT_CODE -eq 0 ] && echo success || echo failed)" "" "$SOLVE_SESSION_ID"

  PHASE1_END=$(date +%s)
  PHASE1_DURATION=$((PHASE1_END - PHASE1_START))
  echo "Phase 1 duration: ${PHASE1_DURATION}s"
  echo "$PHASE1_DURATION" > "${SHARED_DIR}/claude-${ISSUE_KEY}-solve-duration.txt"

  if [ $EXIT_CODE -eq 0 ]; then
    echo "✅ Phase 1 (jira:solve) completed for $ISSUE_KEY"

    # Check if code changes were made (branch changed from main)
    BRANCH_NAME=$(git branch --show-current)
    HAS_CODE_CHANGES=false
    PR_URL=""

    if [ "$BRANCH_NAME" != "main" ] && [ "$BRANCH_NAME" != "master" ] && [ -n "$BRANCH_NAME" ]; then
      DIFF_FILES=$(git diff main...HEAD --name-only 2>/dev/null || echo "")
      if [ -n "$DIFF_FILES" ]; then
        HAS_CODE_CHANGES=true
        echo "Code changes detected on branch '$BRANCH_NAME':"
        echo "$DIFF_FILES" | sed 's/^/  /' | head -20
      fi
    fi

    if [ "$HAS_CODE_CHANGES" = true ]; then
      # === Phase 2: Pre-commit quality review (via /code-review:pre-commit-review skill) ===
      echo ""
      echo "=========================================="
      echo "Phase 2: Pre-commit quality review for $ISSUE_KEY"
      echo "=========================================="

      PHASE2_START=$(date +%s)

      set +e
      run_claude "review" "$ISSUE_KEY" "/code-review:pre-commit-review --language go --profile hypershift" \
        --append-system-prompt "${SECURITY_PROMPT} ${SUBAGENT_PROMPT}" \
        --allowedTools "Bash Read Grep Glob Task Agent Skill" \
        --max-turns 225 \
        --effort max \
        2> "/tmp/claude-${ISSUE_KEY}-review.log" \
        | tee "/tmp/claude-${ISSUE_KEY}-review.json"
      REVIEW_EXIT_CODE=$?
      set -e

      extract_artifacts "/tmp/claude-${ISSUE_KEY}-review.json" "claude-${ISSUE_KEY}-review"
      extract_session_metrics "$ISSUE_KEY" "review"
      extract_tokens "/tmp/claude-${ISSUE_KEY}-review.json" "${SHARED_DIR}/claude-${ISSUE_KEY}-review-tokens.json"
      echo "Phase 2 tokens: $(cat "${SHARED_DIR}/claude-${ISSUE_KEY}-review-tokens.json")"
      generate_autodl "$ISSUE_KEY" "review" "$([ $REVIEW_EXIT_CODE -eq 0 ] && echo success || echo failed)" "" "$(get_session_id "/tmp/claude-${ISSUE_KEY}-review.json")"

      PHASE2_END=$(date +%s)
      PHASE2_DURATION=$((PHASE2_END - PHASE2_START))
      echo "Phase 2 duration: ${PHASE2_DURATION}s"
      echo "$PHASE2_DURATION" > "${SHARED_DIR}/claude-${ISSUE_KEY}-review-duration.txt"

      if [ $REVIEW_EXIT_CODE -eq 0 ]; then
        echo "✅ Phase 2 (pre-commit review) completed for $ISSUE_KEY"
      else
        echo "⚠️ Phase 2 (pre-commit review) failed for $ISSUE_KEY (exit code: $REVIEW_EXIT_CODE)"
        echo "Continuing with PR creation despite review failure..."
      fi

      # === Phase 3: Address review findings (via /openshift-developer:address-review-precommit skill) ===
      echo ""
      echo "=========================================="
      echo "Phase 3: Addressing review findings for $ISSUE_KEY"
      echo "=========================================="

      # Read the review text to feed as context
      REVIEW_FINDINGS=""
      if [ -f "${SHARED_DIR}/claude-${ISSUE_KEY}-review-text.txt" ] && \
         [ -s "${SHARED_DIR}/claude-${ISSUE_KEY}-review-text.txt" ]; then
        REVIEW_FINDINGS=$(cat "${SHARED_DIR}/claude-${ISSUE_KEY}-review-text.txt")
      fi

      # Refresh tokens before Phase 3 since it pushes code.
      # Phases 1-2 can exceed the 1-hour GitHub App token lifetime.
      echo "Refreshing GitHub App tokens before Phase 3..."
      GITHUB_TOKEN_FORK=$(generate_github_token "$INSTALLATION_ID_FORK")
      if [ -z "$GITHUB_TOKEN_FORK" ] || [ "$GITHUB_TOKEN_FORK" = "null" ]; then
        echo "ERROR: Failed to refresh GitHub App token for fork"
      else
        git config --global credential.helper "!f() { echo username=x-access-token; echo password=${GITHUB_TOKEN_FORK}; }; f"
        echo "Fork token refreshed"
      fi

      PHASE3_START=$(date +%s)

      if [ -n "$REVIEW_FINDINGS" ]; then
        set +e
        run_claude "fix" "$ISSUE_KEY" "/openshift-developer:address-review-precommit" \
          --append-system-prompt "REVIEW FINDINGS:
${REVIEW_FINDINGS}

${SECURITY_PROMPT} ${SUBAGENT_PROMPT}" \
          --allowedTools "Bash Read Write Edit Grep Glob Agent Skill Task" \
          --max-turns 225 \
          --effort max \
          2> "/tmp/claude-${ISSUE_KEY}-fix.log" \
          | tee "/tmp/claude-${ISSUE_KEY}-fix.json"
        FIX_EXIT_CODE=$?
        set -e

        extract_artifacts "/tmp/claude-${ISSUE_KEY}-fix.json" "claude-${ISSUE_KEY}-fix"
        extract_session_metrics "$ISSUE_KEY" "fix"
        extract_tokens "/tmp/claude-${ISSUE_KEY}-fix.json" "${SHARED_DIR}/claude-${ISSUE_KEY}-fix-tokens.json"
        echo "Phase 3 tokens: $(cat "${SHARED_DIR}/claude-${ISSUE_KEY}-fix-tokens.json")"
        generate_autodl "$ISSUE_KEY" "fix" "$([ $FIX_EXIT_CODE -eq 0 ] && echo success || echo failed)" "" "$(get_session_id "/tmp/claude-${ISSUE_KEY}-fix.json")"

        if [ $FIX_EXIT_CODE -eq 0 ]; then
          echo "✅ Phase 3 (address review) completed for $ISSUE_KEY"
        else
          echo "⚠️ Phase 3 (address review) failed (exit code: $FIX_EXIT_CODE)"
          echo "Continuing with PR creation..."
        fi
      else
        echo "No review findings to address, skipping Phase 3"
      fi

      PHASE3_END=$(date +%s)
      PHASE3_DURATION=$((PHASE3_END - PHASE3_START))
      echo "Phase 3 duration: ${PHASE3_DURATION}s"
      echo "$PHASE3_DURATION" > "${SHARED_DIR}/claude-${ISSUE_KEY}-fix-duration.txt"

      # Regenerate GitHub App tokens before Phase 4.
      echo "Refreshing GitHub App tokens before Phase 4..."
      GITHUB_TOKEN_FORK=$(generate_github_token "$INSTALLATION_ID_FORK")
      if [ -z "$GITHUB_TOKEN_FORK" ] || [ "$GITHUB_TOKEN_FORK" = "null" ]; then
        echo "ERROR: Failed to refresh GitHub App token for fork"
      else
        git config --global credential.helper "!f() { echo username=x-access-token; echo password=${GITHUB_TOKEN_FORK}; }; f"
        echo "Fork token refreshed"
      fi

      GITHUB_TOKEN_UPSTREAM=$(generate_github_token "$INSTALLATION_ID_UPSTREAM")
      if [ -z "$GITHUB_TOKEN_UPSTREAM" ] || [ "$GITHUB_TOKEN_UPSTREAM" = "null" ]; then
        echo "ERROR: Failed to refresh GitHub App token for upstream"
      else
        export GITHUB_TOKEN="$GITHUB_TOKEN_UPSTREAM"
        echo "Upstream token refreshed"
      fi

      # === Phase 4: Create Pull Request ===
      echo ""
      echo "=========================================="
      echo "Phase 4: Creating Pull Request for $ISSUE_KEY"
      echo "=========================================="

      PHASE4_START=$(date +%s)

      set +e
      run_claude "pr-creation" "$ISSUE_KEY" "/openshift-developer:create-pr ${ISSUE_KEY} --upstream openshift/hypershift --head hypershift-community:${BRANCH_NAME}" \
        --append-system-prompt "${SECURITY_PROMPT} ${SUBAGENT_PROMPT}" \
        --allowedTools "Bash Read Grep Glob" \
        --max-turns 90 \
        --effort max \
        2> "/tmp/claude-${ISSUE_KEY}-pr.log" \
        | tee "/tmp/claude-${ISSUE_KEY}-pr.json"
      PR_EXIT_CODE=$?
      set -e

      extract_artifacts "/tmp/claude-${ISSUE_KEY}-pr.json" "claude-${ISSUE_KEY}-pr"
      extract_session_metrics "$ISSUE_KEY" "pr-creation"
      extract_tokens "/tmp/claude-${ISSUE_KEY}-pr.json" "${SHARED_DIR}/claude-${ISSUE_KEY}-pr-tokens.json"
      echo "Phase 4 tokens: $(cat "${SHARED_DIR}/claude-${ISSUE_KEY}-pr-tokens.json")"

      PHASE4_END=$(date +%s)
      PHASE4_DURATION=$((PHASE4_END - PHASE4_START))
      echo "Phase 4 duration: ${PHASE4_DURATION}s"
      echo "$PHASE4_DURATION" > "${SHARED_DIR}/claude-${ISSUE_KEY}-pr-duration.txt"

      if [ $PR_EXIT_CODE -eq 0 ]; then
        PR_URL=$(grep -o 'https://github.com/openshift/hypershift/pull/[0-9]*' "/tmp/claude-${ISSUE_KEY}-pr.json" | head -1 || echo "")
        if [ -n "$PR_URL" ]; then
          echo "✅ PR created: $PR_URL"
        else
          echo "⚠️ Phase 4 completed but no PR URL found in output"
        fi
      else
        echo "❌ Phase 4 (PR creation) failed for $ISSUE_KEY (exit code: $PR_EXIT_CODE)"
        PR_URL=""
      fi
      generate_autodl "$ISSUE_KEY" "pr-creation" "$([ $PR_EXIT_CODE -eq 0 ] && echo success || echo failed)" "$PR_URL" "$(get_session_id "/tmp/claude-${ISSUE_KEY}-pr.json")"

      # Append report link to PR description
      if [ -n "$PR_URL" ]; then
        PR_NUM=$(echo "$PR_URL" | grep -o '[0-9]*$' || true)
        if [ -n "$PR_NUM" ]; then
          REPORT_URL=""
          if [ -n "${BUILD_ID:-}" ] && [ -n "${JOB_NAME:-}" ]; then
            if [ "${JOB_TYPE:-}" = "periodic" ]; then
              REPORT_URL="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/logs/${JOB_NAME}/${BUILD_ID}/artifacts/periodic-jira-agent/hypershift-jira-agent-report/artifacts/jira-agent-report.html"
            else
              REPORT_URL="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/pr-logs/pull/openshift_release/${PULL_NUMBER:-0}/${JOB_NAME}/${BUILD_ID}/artifacts/periodic-jira-agent/hypershift-jira-agent-report/artifacts/jira-agent-report.html"
            fi
          fi

          if [ -n "$REPORT_URL" ]; then
            echo "Appending report link to PR #${PR_NUM} description..."
            CURRENT_BODY=$(gh pr view "$PR_NUM" --repo openshift/hypershift --json body -q .body 2>/dev/null || echo "")
            REPORT_SECTION="---

> **Note:** This PR was auto-generated by the [jira-agent](https://github.com/openshift/release/tree/main/ci-operator/step-registry/hypershift/jira-agent) periodic CI job in response to [${ISSUE_KEY}](https://redhat.atlassian.net/browse/${ISSUE_KEY}). See the [full report](${REPORT_URL}) for token usage, cost breakdown, and detailed phase output."
            UPDATED_BODY="${CURRENT_BODY}

${REPORT_SECTION}"
            gh pr edit "$PR_NUM" --repo openshift/hypershift --body "$UPDATED_BODY" 2>/dev/null || echo "Warning: Failed to update PR #${PR_NUM} description"
          fi
        fi
      fi

      # Send Slack notification to team channel
      if [ -n "$PR_URL" ] && [ -n "$PR_NUM" ]; then
        send_slack_notification "$PR_URL" "$PR_NUM"
      fi
    else
      echo "No code changes detected for $ISSUE_KEY, skipping review and PR creation"
    fi

    # Add 'agent-processed' label to mark issue as handled
    if [ -n "$JIRA_AUTH" ]; then
      echo "Adding 'agent-processed' label to $ISSUE_KEY..."
      LABEL_RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT \
        "https://redhat.atlassian.net/rest/api/3/issue/$ISSUE_KEY" \
        -H "Authorization: Basic $JIRA_AUTH" \
        -H "Content-Type: application/json" \
        -d '{"update":{"labels":[{"add":"agent-processed"}]}}')
      HTTP_CODE=$(echo "$LABEL_RESPONSE" | tail -1)
      LABEL_BODY=$(echo "$LABEL_RESPONSE" | sed '$d')
      if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
        echo "   Label added successfully"
      else
        echo "   Warning: Failed to add label (HTTP $HTTP_CODE)"
        echo "   Response: $LABEL_BODY"
      fi

      # Transition issue to appropriate status based on project
      if [[ "$ISSUE_KEY" == OCPBUGS-* ]]; then
        TARGET_STATUS="ASSIGNED"
      else
        TARGET_STATUS="Code Review"
      fi

      echo "Transitioning $ISSUE_KEY to '$TARGET_STATUS'..."
      if transition_issue "$ISSUE_KEY" "$TARGET_STATUS"; then
        echo "   Transition successful"
      else
        echo "   Transition failed or not available"
      fi

      # Set assignee to hypershift-team automation (Cloud requires accountId, look it up by display name)
      echo "Looking up accountId for 'hypershift-team automation'..."
      ASSIGNEE_ACCOUNT_ID=$(curl -s -G \
        "https://redhat.atlassian.net/rest/api/3/user/search" \
        -H "Authorization: Basic $JIRA_AUTH" \
        --data-urlencode "query=hypershift-automation" \
        | jq -r '[.[] | select(.displayName == "hypershift-team automation")] | .[0].accountId // empty')
      if [ -n "$ASSIGNEE_ACCOUNT_ID" ]; then
        echo "Setting assignee to account ID '${ASSIGNEE_ACCOUNT_ID}'..."
        ASSIGNEE_RESPONSE=$(set_assignee "$ISSUE_KEY" "$ASSIGNEE_ACCOUNT_ID")
      else
        echo "   Warning: Could not find accountId for 'hypershift-team automation', skipping assignee"
        ASSIGNEE_RESPONSE="skipped
200"
      fi
      HTTP_CODE=$(echo "$ASSIGNEE_RESPONSE" | tail -1)
      if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
        echo "   Assignee set successfully"
      else
        echo "   Warning: Failed to set assignee (HTTP $HTTP_CODE)"
      fi
    fi

    PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
    echo "$ISSUE_KEY $TIMESTAMP $PR_URL SUCCESS" >> "$STATE_FILE"
  else
    # Log failure but don't mark as processed (will be retried next run)
    echo "❌ Failed to process $ISSUE_KEY"
    echo "Error output (last 20 lines):"
    tail -20 "/tmp/claude-${ISSUE_KEY}-output.log"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    echo "$ISSUE_KEY $TIMESTAMP - FAILED" >> "$STATE_FILE"
  fi

  # Increment total counter
  TOTAL_PROCESSED_OR_FAILED=$((TOTAL_PROCESSED_OR_FAILED + 1))

  # Rate limiting between issues (60 seconds)
  # Skip sleep if we've reached the limit
  if [ $TOTAL_PROCESSED_OR_FAILED -lt "$MAX_ISSUES" ]; then
    echo "Waiting 60 seconds before next issue..."
    sleep 60
  fi

done <<< "$ISSUES"

# Generate conversation transcript HTML from stream-json files in /tmp
echo "Generating conversation transcript..."
python3 - "$STATE_FILE" "$ARTIFACT_DIR" << 'TRANSCRIPT_PY'
import json, html, sys, os

state_file = sys.argv[1]
artifact_dir = sys.argv[2]
output_file = os.path.join(artifact_dir, "jira-agent-transcript.html")

PHASES = [
    ("output", "Phase 1: Solve"),
    ("review", "Phase 2: Review"),
    ("fix", "Phase 3: Fix"),
    ("pr", "Phase 4: PR Creation"),
]

def parse_stream_json(path):
    blocks = []
    cost = turns = inp = outp = duration = 0
    model = session = "unknown"
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        try:
            m = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            continue
        t = m.get("type", "")
        if t == "system" and m.get("subtype") == "init":
            model = m.get("model", "unknown")
            session = m.get("session_id", "unknown")
        if t == "result":
            cost = m.get("total_cost_usd", 0)
            turns = m.get("num_turns", 0)
            u = m.get("usage", {})
            inp = u.get("input_tokens", 0)
            outp = u.get("output_tokens", 0)
            duration = m.get("duration_ms", 0)
        if t == "assistant":
            for c in m.get("message", {}).get("content", []):
                ct = c.get("type", "")
                if ct == "text":
                    blocks.append(("assistant", c.get("text", "")))
                elif ct == "tool_use":
                    name = c.get("name", "")
                    inp_str = json.dumps(c.get("input", {}))
                    blocks.append(("tool_use", f"{name}: {inp_str[:300]}"))
        if t == "user":
            r = m.get("tool_use_result", "")
            if isinstance(r, str) and r:
                blocks.append(("tool_result", r[:1000]))
            elif isinstance(r, list):
                for item in r:
                    if isinstance(item, dict) and item.get("type") == "text":
                        blocks.append(("tool_result", item.get("text", "")[:1000]))
    return blocks, {"cost": cost, "turns": turns, "input": inp, "output": outp,
                    "duration": duration, "model": model, "session": session}

def render_blocks(blocks):
    out = []
    for kind, text in blocks:
        escaped = html.escape(text)
        if kind == "assistant":
            out.append(f'<div class="msg a"><div class="label">Assistant</div><pre>{escaped}</pre></div>')
        elif kind == "tool_use":
            out.append(f'<div class="msg t"><div class="label">Tool Call</div><code>{escaped}</code></div>')
        elif kind == "tool_result":
            cls = "e" if text.startswith("Error:") else "r"
            label = "Error" if cls == "e" else "Result"
            out.append(f'<div class="msg {cls}"><div class="label">{label}</div><pre>{escaped}</pre></div>')
    return "\n".join(out)

if not os.path.exists(state_file):
    print("No state file, skipping transcript")
    sys.exit(0)

issues = [l.strip().split()[0] for l in open(state_file) if l.strip()]
sections = []
total_cost = 0

for issue_key in issues:
    issue_sections = []
    for phase_key, phase_label in PHASES:
        stream_file = f"/tmp/claude-{issue_key}-{phase_key}.json"
        if not os.path.exists(stream_file):
            continue
        blocks, stats = parse_stream_json(stream_file)
        if not blocks:
            continue
        total_cost += stats["cost"]
        dur_s = stats["duration"] // 1000
        dur_str = f"{dur_s // 60}m {dur_s % 60}s" if dur_s >= 60 else f"{dur_s}s"
        is_open = "open" if phase_key == "output" else ""
        issue_sections.append(f'''
<details {is_open}>
<summary>{phase_label} — {stats["turns"]} turns, ${stats["cost"]:.4f}, {dur_str}</summary>
<div class="phase">{render_blocks(blocks)}</div>
</details>''')
    if issue_sections:
        sections.append(f'<div class="issue"><h2>{issue_key}</h2>{"".join(issue_sections)}</div>')

with open(output_file, "w") as f:
    f.write(f'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Jira Agent Transcript</title>
<style>
body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; max-width: 1100px; margin: 0 auto; padding: 2em; background: #f5f5f5; color: #333; }}
h1 {{ border-bottom: 2px solid #333; padding-bottom: 0.3em; }}
h2 {{ margin-top: 2em; }}
details {{ margin: 0.5em 0; }}
details summary {{ cursor: pointer; font-weight: 600; color: #555; padding: 0.5em 0; font-size: 1.05em; }}
details[open] summary {{ margin-bottom: 0.5em; }}
.phase {{ border-left: 2px solid #ddd; padding-left: 1em; margin-left: 0.5em; }}
.msg {{ margin: 0.4em 0; padding: 0.6em; border-radius: 6px; }}
.msg .label {{ font-size: 0.7em; font-weight: 600; color: #666; text-transform: uppercase; margin-bottom: 0.2em; }}
.msg pre, .msg code {{ margin: 0; white-space: pre-wrap; word-wrap: break-word; font-size: 0.82em; }}
.msg pre {{ max-height: 250px; overflow-y: auto; }}
.a {{ background: #e8f4fd; border-left: 3px solid #0366d6; }}
.t {{ background: #f6f8fa; border-left: 3px solid #6f42c1; }}
.r {{ background: #f6f8fa; border-left: 3px solid #28a745; }}
.e {{ background: #fff5f5; border-left: 3px solid #cb2431; }}
</style>
</head>
<body>
<p><a href="../../hypershift-jira-agent-report/artifacts/jira-agent-report.html">Back to summary report</a></p>
<h1>Conversation Transcript</h1>
<p style="color:#666">Total cost: ${total_cost:.4f}</p>
{"".join(sections) if sections else "<p>No transcript data available.</p>"}
</body>
</html>''')
print(f"Transcript written: {len(sections)} issue(s)")
TRANSCRIPT_PY

echo ""
echo "=== Processing Summary ==="
echo "Processed: $PROCESSED_COUNT"
echo "Failed: $FAILED_COUNT"
echo "=========================="
