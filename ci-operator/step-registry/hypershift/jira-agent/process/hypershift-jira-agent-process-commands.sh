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

# Check if code-review plugin is available for Phase 2
REVIEW_PLUGIN_DIR="/tmp/ai-helpers/plugins/code-review"
if [ ! -d "${REVIEW_PLUGIN_DIR}/.claude-plugin" ]; then
  echo "ERROR: code-review plugin not found at ${REVIEW_PLUGIN_DIR}/.claude-plugin"
  exit 1
fi
echo "Code-review plugin found"

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
if [ -n "${JIRA_AGENT_ISSUE_KEY:-}" ]; then
  echo "Using override: JIRA_AGENT_ISSUE_KEY=$JIRA_AGENT_ISSUE_KEY"
  JQL="key = ${JIRA_AGENT_ISSUE_KEY}"
else
  JQL="project in (OCPBUGS, CNTRLPLANE) AND resolution = Unresolved AND status in (New, \"To Do\") AND labels = issue-for-agent AND labels != agent-processed"
fi
ISSUES=$(curl -s "https://issues.redhat.com/rest/api/2/search" \
  -G \
  --data-urlencode "jql=$JQL" \
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

  # Run jira-solve command non-interactively using --system-prompt
  # (Claude's -p mode doesn't support slash commands directly)
  TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  echo "Running: jira-solve $ISSUE_KEY origin --ci"

  # Load the skill content as system prompt
  SKILL_CONTENT=$(cat /tmp/hypershift/.claude/commands/jira-solve.md)

  # Additional context for fork-based workflow
  # Git push uses fork token (configured via credential helper), gh CLI uses upstream token (GITHUB_TOKEN env var)
  FORK_CONTEXT="IMPORTANT: You are working in a fork (hypershift-community/hypershift). Git push is pre-configured to work with the fork. After creating commits on your feature branch, push the branch to origin. Do NOT create a Pull Request - the PR will be created in a subsequent automated step after code review. SECURITY: Do NOT run commands that reveal git credentials like 'git remote -v' or 'git remote get-url origin'."

  set +e  # Don't exit on error for individual issues
  echo "Starting Claude processing with streaming output..."
  claude -p "$ISSUE_KEY origin --ci. $FORK_CONTEXT" \
    --system-prompt "$SKILL_CONTENT" \
    --allowedTools "Bash Read Write Edit Grep Glob WebFetch" \
    --max-turns 100 \
    --model "$CLAUDE_MODEL" \
    --verbose \
    --output-format stream-json \
    2> "/tmp/claude-${ISSUE_KEY}-output.log" \
    | tee "/tmp/claude-${ISSUE_KEY}-output.json"
  EXIT_CODE=$?
  set -e
  jq -j 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text // empty' "/tmp/claude-${ISSUE_KEY}-output.json" > "${SHARED_DIR}/claude-${ISSUE_KEY}-output-text.txt" 2>/dev/null || true
  jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | "\(.name): \(.input | keys | join(", "))"' "/tmp/claude-${ISSUE_KEY}-output.json" 2>/dev/null | sort | uniq -c | sort -rn > "${SHARED_DIR}/claude-${ISSUE_KEY}-output-tools.txt" 2>/dev/null || true
  # Extract token usage for Phase 1
  echo "Phase 1: $(wc -l < "/tmp/claude-${ISSUE_KEY}-output.json") total lines in stream-json"
  grep '^{' "/tmp/claude-${ISSUE_KEY}-output.json" > "/tmp/claude-${ISSUE_KEY}-output-filtered.json" 2>/dev/null || true
  echo "Phase 1: $(wc -l < "/tmp/claude-${ISSUE_KEY}-output-filtered.json") JSON lines after filtering"
  jq -s '[.[] | select(.type == "assistant")] | {input_tokens: (map(.message.usage.input_tokens // 0) | add // 0), output_tokens: (map(.message.usage.output_tokens // 0) | add // 0), cache_read_input_tokens: (map(.message.usage.cache_read_input_tokens // 0) | add // 0), cache_creation_input_tokens: (map(.message.usage.cache_creation_input_tokens // 0) | add // 0), model: (.[0].message.model // "unknown")}' "/tmp/claude-${ISSUE_KEY}-output-filtered.json" > "${SHARED_DIR}/claude-${ISSUE_KEY}-solve-tokens.json" 2>/dev/null || echo '{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"model":"unknown"}' > "${SHARED_DIR}/claude-${ISSUE_KEY}-solve-tokens.json"
  echo "Phase 1 tokens: $(cat "${SHARED_DIR}/claude-${ISSUE_KEY}-solve-tokens.json")"

  if [ $EXIT_CODE -eq 0 ]; then
    echo "✅ Phase 1 (jira-solve) completed for $ISSUE_KEY"

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
      # === Phase 2: Pre-commit quality review ===
      echo ""
      echo "=========================================="
      echo "Phase 2: Pre-commit quality review for $ISSUE_KEY"
      echo "=========================================="

      REVIEW_PROMPT="/code-review:pre-commit-review --language go --profile hypershift"

      set +e
      claude -p "$REVIEW_PROMPT" \
        --plugin-dir "${REVIEW_PLUGIN_DIR}" \
        --append-system-prompt "SECURITY: Do NOT run commands that reveal git credentials like 'git remote -v' or 'git remote get-url origin'." \
        --allowedTools "Bash Read Grep Glob Task" \
        --max-turns 75 \
        --model "$CLAUDE_MODEL" \
        --verbose \
        --output-format stream-json \
        2> "/tmp/claude-${ISSUE_KEY}-review.log" \
        | tee "/tmp/claude-${ISSUE_KEY}-review.json"
      REVIEW_EXIT_CODE=$?
      set -e

      jq -j 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text // empty' "/tmp/claude-${ISSUE_KEY}-review.json" > "${SHARED_DIR}/claude-${ISSUE_KEY}-review-text.txt" 2>/dev/null || true
      jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | "\(.name): \(.input | keys | join(", "))"' "/tmp/claude-${ISSUE_KEY}-review.json" 2>/dev/null | sort | uniq -c | sort -rn > "${SHARED_DIR}/claude-${ISSUE_KEY}-review-tools.txt" 2>/dev/null || true
      # Extract token usage for Phase 2
      echo "Phase 2: $(wc -l < "/tmp/claude-${ISSUE_KEY}-review.json") total lines in stream-json"
      grep '^{' "/tmp/claude-${ISSUE_KEY}-review.json" > "/tmp/claude-${ISSUE_KEY}-review-filtered.json" 2>/dev/null || true
      echo "Phase 2: $(wc -l < "/tmp/claude-${ISSUE_KEY}-review-filtered.json") JSON lines after filtering"
      jq -s '[.[] | select(.type == "assistant")] | {input_tokens: (map(.message.usage.input_tokens // 0) | add // 0), output_tokens: (map(.message.usage.output_tokens // 0) | add // 0), cache_read_input_tokens: (map(.message.usage.cache_read_input_tokens // 0) | add // 0), cache_creation_input_tokens: (map(.message.usage.cache_creation_input_tokens // 0) | add // 0), model: (.[0].message.model // "unknown")}' "/tmp/claude-${ISSUE_KEY}-review-filtered.json" > "${SHARED_DIR}/claude-${ISSUE_KEY}-review-tokens.json" 2>/dev/null || echo '{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"model":"unknown"}' > "${SHARED_DIR}/claude-${ISSUE_KEY}-review-tokens.json"
      echo "Phase 2 tokens: $(cat "${SHARED_DIR}/claude-${ISSUE_KEY}-review-tokens.json")"

      if [ $REVIEW_EXIT_CODE -eq 0 ]; then
        echo "✅ Phase 2 (pre-commit review) completed for $ISSUE_KEY"
      else
        echo "⚠️ Phase 2 (pre-commit review) failed for $ISSUE_KEY (exit code: $REVIEW_EXIT_CODE)"
        echo "Continuing with PR creation despite review failure..."
      fi

      # === Phase 3: Address review findings ===
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

      if [ -n "$REVIEW_FINDINGS" ]; then
        FIX_PROMPT="A code review was performed on the changes in the current branch. Below are the review findings. Address all actions and improvements by editing the code. After making all fixes, commit the changes (amend existing commits or create new commits as appropriate) and push the branch to origin.

REVIEW FINDINGS:
${REVIEW_FINDINGS}

IMPORTANT:
- Fix every issue identified in the review — all actions and improvements.
- Run 'make test' and 'make verify' after fixes to verify nothing is broken.
- If 'make verify' generates new files, commit those too and run 'make verify' again to confirm it passes.
- Commit all fixes and push to origin.
- SECURITY: Do NOT run commands that reveal git credentials like 'git remote -v' or 'git remote get-url origin'."

        set +e
        claude -p "$FIX_PROMPT" \
          --allowedTools "Bash Read Write Edit Grep Glob" \
          --max-turns 75 \
          --model "$CLAUDE_MODEL" \
          --verbose \
          --output-format stream-json \
          2> "/tmp/claude-${ISSUE_KEY}-fix.log" \
          | tee "/tmp/claude-${ISSUE_KEY}-fix.json"
        FIX_EXIT_CODE=$?
        set -e

        # Extract fix phase output for report
        jq -j 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text // empty' "/tmp/claude-${ISSUE_KEY}-fix.json" > "${SHARED_DIR}/claude-${ISSUE_KEY}-fix-text.txt" 2>/dev/null || true
        jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | "\(.name): \(.input | keys | join(", "))"' "/tmp/claude-${ISSUE_KEY}-fix.json" 2>/dev/null | sort | uniq -c | sort -rn > "${SHARED_DIR}/claude-${ISSUE_KEY}-fix-tools.txt" 2>/dev/null || true
        # Extract token usage for Phase 3
        echo "Phase 3: $(wc -l < "/tmp/claude-${ISSUE_KEY}-fix.json") total lines in stream-json"
        grep '^{' "/tmp/claude-${ISSUE_KEY}-fix.json" > "/tmp/claude-${ISSUE_KEY}-fix-filtered.json" 2>/dev/null || true
        echo "Phase 3: $(wc -l < "/tmp/claude-${ISSUE_KEY}-fix-filtered.json") JSON lines after filtering"
        jq -s '[.[] | select(.type == "assistant")] | {input_tokens: (map(.message.usage.input_tokens // 0) | add // 0), output_tokens: (map(.message.usage.output_tokens // 0) | add // 0), cache_read_input_tokens: (map(.message.usage.cache_read_input_tokens // 0) | add // 0), cache_creation_input_tokens: (map(.message.usage.cache_creation_input_tokens // 0) | add // 0), model: (.[0].message.model // "unknown")}' "/tmp/claude-${ISSUE_KEY}-fix-filtered.json" > "${SHARED_DIR}/claude-${ISSUE_KEY}-fix-tokens.json" 2>/dev/null || echo '{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"model":"unknown"}' > "${SHARED_DIR}/claude-${ISSUE_KEY}-fix-tokens.json"
        echo "Phase 3 tokens: $(cat "${SHARED_DIR}/claude-${ISSUE_KEY}-fix-tokens.json")"

        if [ $FIX_EXIT_CODE -eq 0 ]; then
          echo "✅ Phase 3 (address review) completed for $ISSUE_KEY"
        else
          echo "⚠️ Phase 3 (address review) failed (exit code: $FIX_EXIT_CODE)"
          echo "Continuing with PR creation..."
        fi
      else
        echo "No review findings to address, skipping Phase 3"
      fi

      # === Phase 4: Create Pull Request ===
      echo ""
      echo "=========================================="
      echo "Phase 4: Creating Pull Request for $ISSUE_KEY"
      echo "=========================================="

      PR_PROMPT="Create a draft pull request for the changes on branch '${BRANCH_NAME}'. Details:
- Jira issue: ${ISSUE_KEY}
- Jira summary: ${ISSUE_SUMMARY}
- Jira URL: https://issues.redhat.com/browse/${ISSUE_KEY}
- Read the PR template at .github/PULL_REQUEST_TEMPLATE.md and use it to structure the PR body.
- Use 'git log main..HEAD' to understand what changed and write a meaningful description.
- PR title must start with '${ISSUE_KEY}: '.
- The PR body MUST end with the following two lines:
  Always review AI generated responses prior to use.
  Generated with [Claude Code](https://claude.com/claude-code) via \`/jira:solve ${ISSUE_KEY}\`
- Create the PR by running: gh pr create --repo openshift/hypershift --head hypershift-community:${BRANCH_NAME} --no-maintainer-edit --draft --title '<title>' --body '<body>'
- After creating the PR, add a comment '/auto-cc' on the PR to assign reviewers.
- SECURITY: Do NOT run commands that reveal git credentials like 'git remote -v' or 'git remote get-url origin'."

      set +e
      claude -p "$PR_PROMPT" \
        --allowedTools "Bash Read Grep Glob" \
        --max-turns 15 \
        --model "$CLAUDE_MODEL" \
        --verbose \
        --output-format stream-json \
        2> "/tmp/claude-${ISSUE_KEY}-pr.log" \
        | tee "/tmp/claude-${ISSUE_KEY}-pr.json"
      PR_EXIT_CODE=$?
      set -e

      jq -j 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text // empty' "/tmp/claude-${ISSUE_KEY}-pr.json" > "${SHARED_DIR}/claude-${ISSUE_KEY}-pr-text.txt" 2>/dev/null || true
      jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | "\(.name): \(.input | keys | join(", "))"' "/tmp/claude-${ISSUE_KEY}-pr.json" 2>/dev/null | sort | uniq -c | sort -rn > "${SHARED_DIR}/claude-${ISSUE_KEY}-pr-tools.txt" 2>/dev/null || true
      # Extract token usage for Phase 4
      echo "Phase 4: $(wc -l < "/tmp/claude-${ISSUE_KEY}-pr.json") total lines in stream-json"
      grep '^{' "/tmp/claude-${ISSUE_KEY}-pr.json" > "/tmp/claude-${ISSUE_KEY}-pr-filtered.json" 2>/dev/null || true
      echo "Phase 4: $(wc -l < "/tmp/claude-${ISSUE_KEY}-pr-filtered.json") JSON lines after filtering"
      jq -s '[.[] | select(.type == "assistant")] | {input_tokens: (map(.message.usage.input_tokens // 0) | add // 0), output_tokens: (map(.message.usage.output_tokens // 0) | add // 0), cache_read_input_tokens: (map(.message.usage.cache_read_input_tokens // 0) | add // 0), cache_creation_input_tokens: (map(.message.usage.cache_creation_input_tokens // 0) | add // 0), model: (.[0].message.model // "unknown")}' "/tmp/claude-${ISSUE_KEY}-pr-filtered.json" > "${SHARED_DIR}/claude-${ISSUE_KEY}-pr-tokens.json" 2>/dev/null || echo '{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"model":"unknown"}' > "${SHARED_DIR}/claude-${ISSUE_KEY}-pr-tokens.json"
      echo "Phase 4 tokens: $(cat "${SHARED_DIR}/claude-${ISSUE_KEY}-pr-tokens.json")"

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

> **Note:** This PR was auto-generated by the [jira-agent](https://github.com/openshift/release/tree/main/ci-operator/step-registry/hypershift/jira-agent) periodic CI job in response to [${ISSUE_KEY}](https://issues.redhat.com/browse/${ISSUE_KEY}). See the [full report](${REPORT_URL}) for token usage, cost breakdown, and detailed phase output."
            UPDATED_BODY="${CURRENT_BODY}

${REPORT_SECTION}"
            gh pr edit "$PR_NUM" --repo openshift/hypershift --body "$UPDATED_BODY" 2>/dev/null || echo "Warning: Failed to update PR #${PR_NUM} description"
          fi
        fi
      fi
    else
      echo "No code changes detected for $ISSUE_KEY, skipping review and PR creation"
    fi

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

echo ""
echo "=== Processing Summary ==="
echo "Processed: $PROCESSED_COUNT"
echo "Failed: $FAILED_COUNT"
echo "=========================="
