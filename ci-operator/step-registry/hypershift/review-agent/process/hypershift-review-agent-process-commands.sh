#!/bin/bash
set -euo pipefail

echo "=== HyperShift Review Agent Process ==="

# This step addresses review comments on a single PR (presubmit mode).
# It uses the /openshift-developer:address-review-pr skill which handles:
# - Fetching and filtering PR comments (deduplication, bot filtering, authorization)
# - Categorizing comments by priority (blocking, change requests, questions, suggestions)
# - Making code changes, posting replies, and pushing

# Determine which PR to process
PR_NUMBER="${REVIEW_AGENT_TARGET_PR:-${PULL_NUMBER:-}}"
if [ -z "$PR_NUMBER" ]; then
  echo "ERROR: No PR number specified. Set PULL_NUMBER (presubmit) or REVIEW_AGENT_TARGET_PR."
  exit 1
fi
echo "Processing PR #$PR_NUMBER"

# State file for sharing results with report step
STATE_FILE="${SHARED_DIR}/processed-prs.txt"

# Clone HyperShift fork (we work on branches here)
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

cd /tmp/hypershift

# Configure git
git config user.name "OpenShift CI Bot"
git config user.email "ci-bot@redhat.com"

# Add upstream remote for PR operations
git remote add upstream https://github.com/openshift/hypershift.git

# Generate GitHub App installation token
echo "Generating GitHub App token..."

GITHUB_APP_CREDS_DIR="/var/run/claude-code-service-account"
APP_ID_FILE="${GITHUB_APP_CREDS_DIR}/app-id"
INSTALLATION_ID_FILE="${GITHUB_APP_CREDS_DIR}/installation-id"
PRIVATE_KEY_FILE="${GITHUB_APP_CREDS_DIR}/private-key"
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

# Generate token for upstream (openshift/hypershift) - for reading PRs and comments
echo "Generating GitHub App token for upstream..."
GITHUB_TOKEN_UPSTREAM=$(generate_github_token "$INSTALLATION_ID_UPSTREAM")
if [ -z "$GITHUB_TOKEN_UPSTREAM" ] || [ "$GITHUB_TOKEN_UPSTREAM" = "null" ]; then
  echo "ERROR: Failed to generate GitHub App token for upstream"
  exit 1
fi
echo "Upstream token generated successfully"

# Configure git to use the fork token for push operations via credential helper
git config --global credential.helper "!f() { echo username=x-access-token; echo password=${GITHUB_TOKEN_FORK}; }; f"

# Export upstream token as GITHUB_TOKEN for gh CLI (used for PR operations)
export GITHUB_TOKEN="$GITHUB_TOKEN_UPSTREAM"
echo "GitHub App tokens configured successfully"

# TODO: Stronger sandboxing (container-level isolation, ai-guardian, PreToolUse hooks)
# tracked in https://redhat.atlassian.net/browse/CNTRLPLANE-3750
DISALLOWED_TOOLS=(
  "Bash(git config*credential*)"
  "Bash(git config*--list*)"
  "Bash(git config*-l*)"
  "Bash(echo*GITHUB_TOKEN*)"
  "Bash(env*)"
  "Bash(printenv*)"
  "Bash(cat*claude-code-service-account*)"
)

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

# Checkout the PR branch
echo "Fetching PR #$PR_NUMBER details..."
PR_INFO=$(gh pr view "$PR_NUMBER" \
  --repo openshift/hypershift \
  --json number,title,headRefName \
  --jq '"\(.number) \(.headRefName) \(.title)"' 2>/dev/null || echo "")

if [ -z "$PR_INFO" ]; then
  echo "ERROR: PR #$PR_NUMBER not found or not accessible"
  exit 1
fi

BRANCH_NAME=$(echo "$PR_INFO" | awk '{print $2}')
PR_TITLE=$(echo "$PR_INFO" | cut -d' ' -f3-)

echo "Branch: $BRANCH_NAME"
echo "Title: $PR_TITLE"

echo "Checking out branch: $BRANCH_NAME"
git fetch origin "$BRANCH_NAME"
git checkout -B "$BRANCH_NAME" "origin/$BRANCH_NAME"

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Run /openshift-developer:address-review-pr skill
echo ""
echo "=========================================="
echo "Addressing review comments for PR #$PR_NUMBER"
echo "=========================================="

PHASE1_START=$(date +%s)

set +e
claude -p "/openshift-developer:address-review-pr $PR_NUMBER" \
  --append-system-prompt "You are addressing review comments on PR #$PR_NUMBER in openshift/hypershift. The PR was created from the hypershift-community fork." \
  --allowedTools "Bash Read Write Edit Grep Glob WebFetch Agent Skill Task" \
  --disallowedTools "${DISALLOWED_TOOLS[@]}" \
  --max-turns 200 \
  --effort max \
  --model "$CLAUDE_MODEL" \
  --verbose \
  --output-format stream-json \
  2> "/tmp/claude-pr-${PR_NUMBER}-output.log" \
  | tee "/tmp/claude-pr-${PR_NUMBER}-output.json"
EXIT_CODE=$?
set -e

# Save raw output to ARTIFACT_DIR for debugging
if [ -f "/tmp/claude-pr-${PR_NUMBER}-output.json" ]; then
  cp "/tmp/claude-pr-${PR_NUMBER}-output.json" "${ARTIFACT_DIR}/claude-pr-${PR_NUMBER}-output.json" 2>/dev/null || true
fi

# Extract artifacts for the report step (same helper functions as jira-agent)
extract_artifacts "/tmp/claude-pr-${PR_NUMBER}-output.json" "claude-pr-${PR_NUMBER}-review"
extract_tokens "/tmp/claude-pr-${PR_NUMBER}-output.json" "${SHARED_DIR}/claude-pr-${PR_NUMBER}-review-tokens.json"
echo "Token usage: $(cat "${SHARED_DIR}/claude-pr-${PR_NUMBER}-review-tokens.json")"

PHASE_END=$(date +%s)
PHASE_DURATION=$((PHASE_END - PHASE1_START))
echo "Duration: ${PHASE_DURATION}s"
echo "$PHASE_DURATION" > "${SHARED_DIR}/claude-pr-${PR_NUMBER}-review-duration.txt"

if [ $EXIT_CODE -eq 0 ]; then
  echo "✅ Review comments addressed for PR #$PR_NUMBER"
  echo "$PR_NUMBER $TIMESTAMP SUCCESS" >> "$STATE_FILE"
else
  echo "❌ Failed to address review comments for PR #$PR_NUMBER (exit code: $EXIT_CODE)"
  echo "Error output (last 20 lines):"
  tail -20 "/tmp/claude-pr-${PR_NUMBER}-output.log"
  echo "$PR_NUMBER $TIMESTAMP FAILED" >> "$STATE_FILE"
fi

echo ""
echo "=== Processing Summary ==="
echo "PR: #$PR_NUMBER"
echo "Result: $([ $EXIT_CODE -eq 0 ] && echo 'SUCCESS' || echo 'FAILED')"
echo "=========================="
