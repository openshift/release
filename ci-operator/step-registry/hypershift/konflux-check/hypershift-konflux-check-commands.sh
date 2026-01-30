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

# Additional context for fork-based workflow
FORK_CONTEXT="IMPORTANT: You are working in a fork (hypershift-community/hypershift). Git push is pre-configured to work with the fork. After pushing the branch, you MUST create the PR by running: gh pr create --repo openshift/hypershift --head hypershift-community:$BRANCH_NAME --no-maintainer-edit --draft --title '<title>' --body '<body>'. The gh CLI is authenticated to openshift/hypershift. Do NOT skip PR creation - this is a required step. SECURITY: Do NOT run commands that reveal git credentials like 'git remote -v' or 'git remote get-url origin'."

# Run the update-konflux-tasks skill
echo "Running /update-konflux-tasks skill..."

set +e  # Don't exit on error
RESULT=$(claude -p "/update-konflux-tasks. $FORK_CONTEXT" \
  --allowedTools "Bash Read Write Edit Grep Glob WebFetch mcp__atlassian__jira_create_issue mcp__atlassian__jira_search mcp__atlassian__jira_add_comment" \
  --max-turns 100 \
  --verbose \
  --output-format stream-json \
  2>&1 | tee "/tmp/claude-konflux-output.json")
EXIT_CODE=$?
set -e

echo "Claude processing complete. Full output saved to /tmp/claude-konflux-output.json"

if [ $EXIT_CODE -eq 0 ]; then
  # Check if there are any changes to commit
  if git diff --quiet && git diff --cached --quiet; then
    echo "No changes detected. Konflux tasks are up to date."
    exit 0
  fi

  # Parse PR URL from result if available
  PR_URL=$(echo "$RESULT" | grep -oP 'https://github.com/openshift/hypershift/pull/[0-9]+' | head -1 || echo "")

  echo "Successfully processed Konflux task updates"
  if [ -n "$PR_URL" ]; then
    echo "PR: $PR_URL"
  else
    echo "Note: No PR URL found in output. Claude may have encountered an issue creating the PR."
  fi

  echo ""
  echo "--- Claude output ---"
  echo "$RESULT"
  echo "--- End Claude output ---"
else
  echo "Failed to process Konflux task updates"
  echo "Error output (last 50 lines):"
  echo "$RESULT" | tail -50
  exit 1
fi

echo ""
echo "=== Konflux Task Update Check Complete ==="
