#!/bin/bash
set -euo pipefail

echo "=== HyperShift Dependabot Triage Process ==="

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
  local IAT
  local EXP
  local HEADER
  local PAYLOAD
  local SIGNATURE
  local JWT

  NOW=$(date +%s)
  IAT=$((NOW - 60))
  EXP=$((NOW + 600))

  HEADER=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
  PAYLOAD=$(echo -n "{\"iat\":${IAT},\"exp\":${EXP},\"iss\":\"${APP_ID}\"}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
  SIGNATURE=$(echo -n "${HEADER}.${PAYLOAD}" | openssl dgst -sha256 -sign "$PRIVATE_KEY_FILE" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
  JWT="${HEADER}.${PAYLOAD}.${SIGNATURE}"

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

# Clone HyperShift repository from fork
echo "Cloning HyperShift repository..."
mkdir -p /tmp/dependabot-triage
cd /tmp/dependabot-triage
git clone https://github.com/hypershift-community/hypershift hypershift
cd hypershift

# Add upstream remote
echo "Adding upstream remote..."
git remote add upstream https://github.com/openshift/hypershift.git
git fetch upstream

# Configure git
echo "Configuring git..."
git config user.name "OpenShift CI Bot"
git config user.email "ci-bot@redhat.com"

# Configure git to use the fork token for push operations via credential helper
# Using credential helper instead of URL rewriting prevents token leaking in git remote output
git config --global credential.helper "!f() { echo username=x-access-token; echo password=${GITHUB_TOKEN_FORK}; }; f"

# Export upstream token as GITHUB_TOKEN for gh CLI (used for PR operations)
export GITHUB_TOKEN="$GITHUB_TOKEN_UPSTREAM"
echo "GitHub App tokens configured successfully"

# Query GitHub for open dependabot PRs
echo "Querying GitHub for open dependabot PRs..."
DEPENDABOT_PRS=$(gh pr list \
  --repo openshift/hypershift \
  --author "app/dependabot" \
  --state open \
  --json number,title,headRefName \
  --limit 50)

# Filter out PRs that bump k8s.io or sigs.k8s.io dependencies (managed manually)
echo "Filtering out k8s.io and sigs.k8s.io dependency bumps..."
FILTERED_PRS="[]"
while IFS= read -r pr_json; do
  pr_num=$(echo "$pr_json" | jq -r '.number')
  pr_title=$(echo "$pr_json" | jq -r '.title')
  pr_diff=$(gh api "repos/openshift/hypershift/pulls/${pr_num}/files" \
    --jq '.[] | select(.filename == "go.mod" or .filename == "api/go.mod") | .patch' 2>/dev/null || true)
  if echo "$pr_diff" | grep -qE '^\+[^+].*\b(k8s\.io|sigs\.k8s\.io)/'; then
    echo "  Skipping PR #${pr_num}: ${pr_title} (contains k8s.io/sigs.k8s.io changes)"
  else
    FILTERED_PRS=$(echo "$FILTERED_PRS" | jq --argjson pr "$pr_json" '. + [$pr]')
  fi
done < <(echo "$DEPENDABOT_PRS" | jq -c '.[]')
DEPENDABOT_PRS="$FILTERED_PRS"

PR_COUNT=$(echo "$DEPENDABOT_PRS" | jq 'length')
echo "Found $PR_COUNT open dependabot PRs"

if [ "$PR_COUNT" -eq 0 ]; then
  echo "No open dependabot PRs found. Nothing to do."
  exit 0
fi

# Extract PR numbers
PR_NUMBERS=$(echo "$DEPENDABOT_PRS" | jq -r '.[].number' | tr '\n' ' ')
echo "PR numbers to process: $PR_NUMBERS"

# Display PR titles for logging
echo ""
echo "PRs to process:"
echo "$DEPENDABOT_PRS" | jq -r '.[] | "  #\(.number): \(.title)"'
echo ""

# Build the Claude prompt
read -r -d '' CLAUDE_PROMPT << 'PROMPT_EOF' || true
Process the following dependabot PRs and consolidate them into a single PR.

PR Numbers: ${PR_NUMBERS}

## Critical: Process Each PR Individually with Validation

You MUST process each PR one at a time, validating after each before moving to the next.
This ensures we know exactly which PR fails if something breaks.

### Phase 1: Setup
1. Create a new branch 'fix/weekly-dependabot-consolidation' from upstream/main
2. Initialize tracking lists for succeeded_prs and failed_prs

### Phase 2: Process Each PR (one at a time, in order)

For EACH PR in the list above, do the following steps IN ORDER:

1. **Save current state**: Note the current HEAD commit SHA before starting this PR

2. **Cherry-pick**: Fetch and cherry-pick the PR's commits onto the branch
   - Convert commit messages to conventional format (chore(deps): ...)
   - If cherry-pick fails: record PR as failed with reason, reset to saved SHA, continue to next PR

3. **Run make verify**: Regenerate all necessary files
   - If make verify fails: record PR as failed with reason, reset to saved SHA, continue to next PR

4. **Run UPDATE=true make test**: Update test fixtures
   - If make test fails: record PR as failed with reason, reset to saved SHA, continue to next PR

5. **Commit generated changes**: Commit any files changed by make verify/test
   - Use message: "chore: regenerate files for PR #<number>"

6. **Record success**: Add this PR to succeeded_prs list

7. **Move to next PR**: Repeat steps 1-6 for the next PR

### Phase 3: Reorganize Commits (only if at least one PR succeeded)

After processing all PRs, reorganize the accumulated commits into logical groups:
1. First commit: go.mod/go.sum changes ONLY (for easy review of actual dependency changes)
2. Second commit: vendor/ updates
3. Third commit: api/ module changes (api/go.mod, api/go.sum, api/vendor/)
4. Fourth commit: regenerated assets (cmd/install/assets/)
5. Fifth commit: any other generated changes

### Phase 4: Final Validation
1. Run make verify - must pass
2. Run make test - must pass

### Phase 5: Create Consolidated PR

If at least one PR was successfully processed:
1. Push the branch to origin
2. Create a single consolidated PR with title: 'NO-JIRA: chore(deps): weekly dependabot consolidation'
   - Use: gh pr create --repo openshift/hypershift --head hypershift-community:fix/weekly-dependabot-consolidation --no-maintainer-edit --draft

PR body format:
## Summary
Weekly consolidation of dependabot dependency updates.

## Consolidated PRs
- #123: bump foo from 1.0 to 1.1
- #124: bump bar from 2.0 to 2.1
[list all successfully processed PRs with their titles]

## Failed PRs (if any)
- #125: cherry-pick conflict in go.mod
- #126: make verify failed
[list any PRs that could not be processed with failure reasons]

## Commits
1. go.mod/go.sum dependency updates
2. Vendored dependencies
3. API module updates
4. Regenerated CRD assets
5. Other generated changes (if any)

---
Assisted-by: Claude (via Claude Code)

### Phase 6: Report Results and Exit
Report which PRs succeeded, which failed (with reasons), and the new PR URL.

IMPORTANT: After reporting results, you are DONE. Do not attempt any additional operations like closing original PRs or making further changes. Exit immediately after reporting.
PROMPT_EOF

# Substitute PR numbers into prompt
CLAUDE_PROMPT="${CLAUDE_PROMPT//\$\{PR_NUMBERS\}/$PR_NUMBERS}"

echo "Invoking Claude to process and consolidate PRs..."
echo "=========================================="

# Run Claude with explicit tool allowlist
set +e
RESULT=$(echo "$CLAUDE_PROMPT" | claude --print \
  --allowedTools "Bash,Read,Write,Edit,Grep,Glob,WebFetch,Skill,Task,TodoWrite" \
  --output-format json \
  --max-turns 100 \
  2>&1)
EXIT_CODE=$?
set -e

echo "=========================================="
echo ""

if [ $EXIT_CODE -eq 0 ]; then
  echo "Claude processing completed successfully"

  # Try to extract PR URL from result
  NEW_PR_URL=$(echo "$RESULT" | grep -oP 'https://github.com/openshift/hypershift/pull/[0-9]+' | head -1 || echo "")

  if [ -n "$NEW_PR_URL" ]; then
    echo ""
    echo "=========================================="
    echo "SUCCESS"
    echo "=========================================="
    echo "Consolidated PR: $NEW_PR_URL"
  else
    echo ""
    echo "Processing completed but no PR URL found in output."
    echo "Check the logs above for details."
  fi
else
  echo ""
  echo "=========================================="
  echo "PROCESSING FAILED"
  echo "=========================================="
  echo "Exit code: $EXIT_CODE"
  echo ""
  echo "Last 50 lines of output:"
  echo "$RESULT" | tail -50
  exit 1
fi

echo ""
echo "=== Dependabot Triage Complete ==="
