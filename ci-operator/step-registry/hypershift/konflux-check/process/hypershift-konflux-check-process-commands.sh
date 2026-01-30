#!/bin/bash
set -euo pipefail

echo "=== HyperShift Konflux Task Update Check ==="

# Clone HyperShift fork (we push here and create PRs to upstream)
echo "Cloning HyperShift repository..."
git clone https://github.com/hypershift-community/hypershift /tmp/hypershift

cd /tmp/hypershift

# Configure git
git config user.name "OpenShift CI Bot"
git config user.email "ci-bot@redhat.com"

# Generate GitHub App installation token
echo "Generating GitHub App token..."

GITHUB_APP_CREDS_DIR="/var/run/claude-code-service-account"
APP_ID_FILE="${GITHUB_APP_CREDS_DIR}/app-id"
INSTALLATION_ID_FILE="${GITHUB_APP_CREDS_DIR}/installation-id"
PRIVATE_KEY_FILE="${GITHUB_APP_CREDS_DIR}/private-key"
INSTALLATION_ID_UPSTREAM_FILE="${GITHUB_APP_CREDS_DIR}/o-h-installation-id"

# Check if all required credentials exist
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
  echo "STATUS:NO_CREDENTIALS" > "${SHARED_DIR}/konflux-check-results.txt"
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
git config --global credential.helper "!f() { echo username=x-access-token; echo password=${GITHUB_TOKEN_FORK}; }; f"

# Export upstream token as GITHUB_TOKEN for gh CLI (used for PR creation)
export GITHUB_TOKEN="$GITHUB_TOKEN_UPSTREAM"
echo "GitHub App tokens configured successfully"

# Load Jira API token for creating tickets
JIRA_TOKEN_FILE="/var/run/claude-code-service-account/jira-pat"
if [ -f "$JIRA_TOKEN_FILE" ]; then
  JIRA_TOKEN=$(cat "$JIRA_TOKEN_FILE")
  export JIRA_TOKEN
  echo "Jira API token loaded from jira-pat"
else
  echo "Warning: Jira API token not found at $JIRA_TOKEN_FILE"
  echo "Jira tickets will not be created"
  JIRA_TOKEN=""
fi

# Create branch name with date
BRANCH_NAME="konflux-task-update-$(date +%Y%m%d)"
echo "Creating branch: $BRANCH_NAME"
git checkout -b "$BRANCH_NAME"

# Record the starting commit SHA so we can detect changes after Claude runs
START_SHA=$(git rev-parse HEAD)

# Additional context for fork-based workflow
FORK_CONTEXT="IMPORTANT: You are working in a fork (hypershift-community/hypershift). Git push is pre-configured to work with the fork. CRITICAL: When running hack/tools/scripts/update_trusted_task_bundles.py, you MUST pass --upgrade-versions to detect and apply version bumps (e.g. 0.7 to 0.9), not just digest updates within the same version. CRITICAL: After applying all updates, you MUST complete these steps in order: 1) git add -A && git commit -m 'chore(ci): update Konflux Tekton tasks to latest versions' 2) git push origin $BRANCH_NAME 3) gh pr create --repo openshift/hypershift --head hypershift-community:$BRANCH_NAME --no-maintainer-edit --title 'NO-JIRA: chore(ci): update Konflux Tekton tasks to latest versions' --body '<body>'. The gh CLI is authenticated to openshift/hypershift. Do NOT skip commit, push, or PR creation - these are ALL required steps. SECURITY: Do NOT run commands that reveal git credentials like 'git remote -v' or 'git remote get-url origin'."

# Run the update-konflux-tasks skill
echo "Running /update-konflux-tasks skill..."

CLAUDE_OUTPUT_FILE="/tmp/claude-konflux-output.json"
CLAUDE_START_TIME=$(date +%s)

set +e  # Don't exit on error
echo "/update-konflux-tasks. $FORK_CONTEXT" | claude --print \
  --allowedTools "Bash,Read,Write,Edit,Grep,Glob,WebFetch,mcp__atlassian__jira_create_issue,mcp__atlassian__jira_search,mcp__atlassian__jira_add_comment" \
  --max-turns 100 \
  --verbose \
  --output-format stream-json \
  2> "/tmp/claude-konflux-stderr.log" \
  | tee "$CLAUDE_OUTPUT_FILE"
CLAUDE_EXIT_CODE=$?
set -e

CLAUDE_END_TIME=$(date +%s)
CLAUDE_DURATION=$((CLAUDE_END_TIME - CLAUDE_START_TIME))
echo "$CLAUDE_DURATION" > "${SHARED_DIR}/claude-konflux-duration.txt"

echo "Claude processing complete (exit code: $CLAUDE_EXIT_CODE, duration: ${CLAUDE_DURATION}s)"

# Extract token usage from stream-json result message
grep '"type":"result"' "$CLAUDE_OUTPUT_FILE" \
  | head -1 \
  | jq '{
      total_cost_usd: (.total_cost_usd // 0),
      duration_ms: (.duration_ms // 0),
      num_turns: (.num_turns // 0),
      input_tokens: (.input_tokens // 0),
      output_tokens: (.output_tokens // 0),
      cache_read_input_tokens: (.cache_read_input_tokens // 0),
      cache_creation_input_tokens: (.cache_creation_input_tokens // 0),
      model_usage: (.model_usage // {}),
      model: (.model // "unknown")
    }' > "${SHARED_DIR}/claude-konflux-tokens.json" 2>/dev/null \
  || echo '{"total_cost_usd":0,"duration_ms":0,"num_turns":0,"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"model_usage":{},"model":"unknown"}' > "${SHARED_DIR}/claude-konflux-tokens.json"
echo "Token usage: $(cat "${SHARED_DIR}/claude-konflux-tokens.json")"

# Extract Claude text output and tool usage summaries
jq -r '
  if .type == "assistant" then
    .message.content[]? |
    if .type == "text" then .text
    else empty end
  else empty end
' "$CLAUDE_OUTPUT_FILE" > "${SHARED_DIR}/claude-konflux-output-text.txt" 2>/dev/null || true

jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | "\(.name): \(.input | keys | join(", "))"' "$CLAUDE_OUTPUT_FILE" 2>/dev/null \
  | sort | uniq -c | sort -rn > "${SHARED_DIR}/claude-konflux-output-tools.txt" 2>/dev/null || true

# Copy stderr log to artifacts
cp "/tmp/claude-konflux-stderr.log" "${ARTIFACT_DIR}/claude-stderr.log" 2>/dev/null || true

# Detect whether Claude actually made changes by comparing HEAD to the starting SHA
END_SHA=$(git rev-parse HEAD)
RESULTS_FILE="${SHARED_DIR}/konflux-check-results.txt"

if [ "$START_SHA" != "$END_SHA" ]; then
  # Claude committed changes - count the commits
  COMMIT_COUNT=$(git rev-list "${START_SHA}..HEAD" --count)
  echo "Detected $COMMIT_COUNT new commit(s)"

  # Extract PR URL from Claude output if available
  PR_URL=$(jq -r '
    if .type == "assistant" then
      .message.content[]? |
      if .type == "text" then .text
      else empty end
    else empty end
  ' "$CLAUDE_OUTPUT_FILE" 2>/dev/null | grep -oE 'https://github.com/openshift/hypershift/pull/[0-9]+' | head -1 || echo "")

  # Get the list of updated tasks from git diff
  CHANGED_FILES=$(git diff --name-only "${START_SHA}..HEAD" | sort)

  {
    echo "STATUS:UPDATED"
    echo "COMMITS:$COMMIT_COUNT"
    echo "PR_URL:${PR_URL:-none}"
    echo "START_SHA:$START_SHA"
    echo "END_SHA:$END_SHA"
    echo "CHANGED_FILES:$CHANGED_FILES"
  } > "$RESULTS_FILE"

  # Extract the commit messages for the report
  git log --format="%s" "${START_SHA}..HEAD" > "${SHARED_DIR}/konflux-check-commits.txt" 2>/dev/null || true

  echo ""
  echo "Konflux task updates applied successfully."
  if [ -n "$PR_URL" ]; then
    echo "PR: $PR_URL"
    echo "$PR_URL" > "${SHARED_DIR}/konflux-check-pr-url.txt"

    # Append report link to PR description
    PR_NUM=$(echo "$PR_URL" | grep -o '[0-9]*$' || true)
    if [ -n "$PR_NUM" ] && [ -n "${BUILD_ID:-}" ] && [ -n "${JOB_NAME:-}" ]; then
      REPORT_URL=""
      if [ "${JOB_TYPE:-}" = "periodic" ]; then
        REPORT_URL="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/logs/${JOB_NAME}/${BUILD_ID}/artifacts/periodic-konflux-check/hypershift-konflux-check-report/artifacts/konflux-check-report.html"
      else
        REPORT_URL="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/pr-logs/pull/openshift_release/${PULL_NUMBER:-0}/${JOB_NAME}/${BUILD_ID}/artifacts/periodic-konflux-check/hypershift-konflux-check-report/artifacts/konflux-check-report.html"
      fi
      echo "Appending report link to PR #${PR_NUM} description..."
      CURRENT_BODY=$(gh pr view "$PR_NUM" --repo openshift/hypershift --json body -q .body 2>/dev/null || echo "")
      REPORT_SECTION="---

> **Note:** This PR was auto-generated by the [konflux-check](https://github.com/openshift/release/tree/main/ci-operator/step-registry/hypershift/konflux-check) periodic CI job. See the [full report](${REPORT_URL}) for token usage, cost breakdown, and detailed output."
      UPDATED_BODY="${CURRENT_BODY}

${REPORT_SECTION}"
      gh pr edit "$PR_NUM" --repo openshift/hypershift --body "$UPDATED_BODY" 2>/dev/null || echo "Warning: Failed to update PR #${PR_NUM} description"
    fi
  else
    echo "Warning: No PR URL found in Claude output."
  fi
else
  echo "No changes detected. Konflux tasks are up to date."
  echo "STATUS:UP_TO_DATE" > "$RESULTS_FILE"
fi

if [ $CLAUDE_EXIT_CODE -ne 0 ]; then
  echo "WARNING: Claude exited with non-zero status ($CLAUDE_EXIT_CODE)"
  echo "CLAUDE_EXIT_CODE:$CLAUDE_EXIT_CODE" >> "$RESULTS_FILE"
fi

echo ""
echo "=== Konflux Task Update Check Complete ==="
