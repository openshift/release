#!/bin/bash
set -euo pipefail

echo "=== HyperShift Jira Agent Process ==="

# State file for sharing results with report step
STATE_FILE="${SHARED_DIR}/processed-issues.txt"

# Clone ai-helpers repository (contains /jira-solve command)
echo "Cloning ai-helpers repository..."
git clone https://github.com/openshift-eng/ai-helpers /tmp/ai-helpers

# Clone HyperShift fork (we push here and create PRs to upstream)
echo "Cloning HyperShift repository..."
git clone https://github.com/hypershift-community/hypershift /tmp/hypershift

# Copy jira-solve command from ai-helpers to hypershift
echo "Setting up Claude commands..."
mkdir -p /tmp/hypershift/.claude/commands
cp /tmp/ai-helpers/plugins/jira/commands/solve.md /tmp/hypershift/.claude/commands/jira-solve.md

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

# Load Jira API token for adding labels after processing
JIRA_TOKEN_FILE="/var/run/claude-code-service-account/jira-pat"
if [ -f "$JIRA_TOKEN_FILE" ]; then
  JIRA_TOKEN=$(cat "$JIRA_TOKEN_FILE")
  echo "Jira API token loaded from jira-pat"
else
  echo "Warning: Jira API token not found at $JIRA_TOKEN_FILE"
  echo "Labels will not be added to processed issues"
  JIRA_TOKEN=""
fi

# Function to transition a Jira issue to a target status
transition_issue() {
  local ISSUE_KEY=$1
  local TARGET_STATUS=$2

  # Get available transitions
  TRANSITIONS=$(curl -s \
    "https://issues.redhat.com/rest/api/2/issue/$ISSUE_KEY/transitions" \
    -H "Authorization: Bearer $JIRA_TOKEN" \
    -H "Content-Type: application/json")

  # Find transition ID for target status (match by name)
  TRANSITION_ID=$(echo "$TRANSITIONS" | jq -r --arg status "$TARGET_STATUS" \
    '.transitions[] | select(.name == $status) | .id' | head -1)

  if [ -n "$TRANSITION_ID" ] && [ "$TRANSITION_ID" != "null" ]; then
    curl -s -X POST \
      "https://issues.redhat.com/rest/api/2/issue/$ISSUE_KEY/transitions" \
      -H "Authorization: Bearer $JIRA_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"transition\":{\"id\":\"$TRANSITION_ID\"}}"
    return 0
  else
    echo "   Warning: Transition to '$TARGET_STATUS' not available"
    return 1
  fi
}

# Function to set assignee on a Jira issue
set_assignee() {
  local ISSUE_KEY=$1
  local ASSIGNEE_NAME=$2

  curl -s -w "\n%{http_code}" -X PUT \
    "https://issues.redhat.com/rest/api/2/issue/$ISSUE_KEY/assignee" \
    -H "Authorization: Bearer $JIRA_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$ASSIGNEE_NAME\"}"
}

# Query Jira for issues (excluding already processed ones via label)
echo "Querying Jira for issues..."
ISSUES=$(curl -s "https://issues.redhat.com/rest/api/2/search" \
  -G \
  --data-urlencode 'jql=project in (OCPBUGS, CNTRLPLANE) AND resolution = Unresolved AND status in (New, "To Do") AND labels = issue-for-agent AND labels != agent-processed' \
  --data-urlencode 'fields=key,summary' \
  --data-urlencode "maxResults=$MAX_ISSUES" \
  | jq -r '.issues[]? | "\(.key) \(.fields.summary)"')

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
  ISSUE_KEY=$(echo "$line" | awk '{print $1}')
  ISSUE_SUMMARY=$(echo "$line" | cut -d' ' -f2-)

  echo ""
  echo "=========================================="
  echo "Processing: $ISSUE_KEY"
  echo "Summary: $ISSUE_SUMMARY"
  echo "=========================================="

  # Run jira-solve command non-interactively using --system-prompt
  # (Claude's -p mode doesn't support slash commands directly)
  TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  echo "Running: jira-solve $ISSUE_KEY origin --ci"

  # Load the skill content as system prompt
  SKILL_CONTENT=$(cat /tmp/hypershift/.claude/commands/jira-solve.md)

  # Additional context for fork-based workflow
  # Git push uses fork token (configured via credential helper), gh CLI uses upstream token (GITHUB_TOKEN env var)
  FORK_CONTEXT="IMPORTANT: You are working in a fork (hypershift-community/hypershift). Git push is pre-configured to work with the fork. After pushing the branch, you MUST create the PR by running: gh pr create --repo openshift/hypershift --head hypershift-community:<branch-name> --no-maintainer-edit --draft --title '<title>' --body '<body>'. The PR body MUST end with the following disclaimer on its own line: 'Always review AI generated responses prior to use.' The gh CLI is authenticated to openshift/hypershift. Do NOT skip PR creation - this is a required step. SECURITY: Do NOT run commands that reveal git credentials like 'git remote -v' or 'git remote get-url origin'."

  set +e  # Don't exit on error for individual issues
  echo "Starting Claude processing with streaming output..."
  RESULT=$(claude -p "$ISSUE_KEY origin --ci. $FORK_CONTEXT" \
    --system-prompt "$SKILL_CONTENT" \
    --allowedTools "Bash Read Write Edit Grep Glob WebFetch" \
    --max-turns 100 \
    --model "$CLAUDE_MODEL" \
    --verbose \
    --output-format stream-json \
    2>&1 | tee "/tmp/claude-${ISSUE_KEY}-output.json")
  EXIT_CODE=$?
  set -e
  echo "Claude processing complete. Full output saved to /tmp/claude-${ISSUE_KEY}-output.json"

  if [ $EXIT_CODE -eq 0 ]; then
    # Parse PR URL from result if available
    PR_URL=$(echo "$RESULT" | grep -oP 'https://github.com/openshift/hypershift/pull/[0-9]+' | head -1 || echo "")

    echo "✅ Successfully processed $ISSUE_KEY"
    if [ -n "$PR_URL" ]; then
      echo "   PR: $PR_URL"
      # Add /auto-cc comment to assign reviewers
      echo "   Adding /auto-cc comment to assign reviewers..."
      if gh pr comment "$PR_URL" --body "/auto-cc"; then
        echo "   /auto-cc comment added successfully"
      else
        echo "   Warning: Failed to add /auto-cc comment"
      fi
    else
      echo "   Note: No PR URL found in output. Claude may have encountered an issue creating the PR."
    fi

    echo ""
    echo "--- Claude output for $ISSUE_KEY ---"
    echo "$RESULT"
    echo "--- End Claude output ---"
    echo ""

    # Add 'agent-processed' label to mark issue as handled
    if [ -n "$JIRA_TOKEN" ]; then
      echo "Adding 'agent-processed' label to $ISSUE_KEY..."
      LABEL_RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT \
        "https://issues.redhat.com/rest/api/2/issue/$ISSUE_KEY" \
        -H "Authorization: Bearer $JIRA_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"update":{"labels":[{"add":"agent-processed"}]}}')
      HTTP_CODE=$(echo "$LABEL_RESPONSE" | tail -1)
      if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
        echo "   Label added successfully"
      else
        echo "   Warning: Failed to add label (HTTP $HTTP_CODE)"
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

      # Set assignee to hypershift-automation
      echo "Setting assignee to 'hypershift-automation'..."
      ASSIGNEE_RESPONSE=$(set_assignee "$ISSUE_KEY" "hypershift-automation")
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
    echo "$RESULT" | tail -20
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

echo ""
echo "=== Processing Summary ==="
echo "Processed: $PROCESSED_COUNT"
echo "Failed: $FAILED_COUNT"
echo "=========================="
