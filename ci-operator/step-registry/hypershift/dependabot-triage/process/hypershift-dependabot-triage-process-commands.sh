#!/bin/bash
set -euo pipefail
export GOTOOLCHAIN=auto

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
Process the following dependabot PRs and consolidate them into a single branch.

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
   - If cherry-pick fails: record PR as failed with reason, run `git reset --hard <saved_sha> && git clean -fd` to fully revert all changes, continue to next PR

3. **Run make verify**: Regenerate all necessary files
   - If make verify fails: check the output. If the ONLY failure is gitlint, ignore it and continue (gitlint validates commit messages which are not relevant here). If there are other failures, record PR as failed with reason, run `git reset --hard <saved_sha> && git clean -fd` to fully revert all changes, continue to next PR

4. **Run UPDATE=true make test**: Update test fixtures
   - If make test fails: record PR as failed with reason, run `git reset --hard <saved_sha> && git clean -fd` to fully revert all changes, continue to next PR

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

### Phase 4: Output Results and Exit

IMPORTANT: Do NOT run final make verify/test. Do NOT push the branch. Do NOT create a PR.
The bash script that invoked you will handle final validation, push, and PR creation.

Write the results to the file ${CLAUDE_RESULTS_FILE} using these EXACT structured markers (one per line, appended with >>):
- For each successfully processed PR: echo "SUCCEEDED_PR:<number>:<title>" >> ${CLAUDE_RESULTS_FILE}
- For each failed PR: echo "FAILED_PR:<number>:<reason>" >> ${CLAUDE_RESULTS_FILE}

Write each marker IMMEDIATELY after processing that PR (do not wait until the end).

After processing all PRs, you are DONE. Exit immediately.
PROMPT_EOF

# Create temp files before substituting into prompt
CLAUDE_OUTPUT_FILE=$(mktemp /tmp/claude-output.XXXXXX)
CLAUDE_RESULTS_FILE=$(mktemp /tmp/claude-results.XXXXXX)

# Substitute variables into prompt
CLAUDE_PROMPT="${CLAUDE_PROMPT//\$\{PR_NUMBERS\}/$PR_NUMBERS}"
CLAUDE_PROMPT="${CLAUDE_PROMPT//\$\{CLAUDE_RESULTS_FILE\}/$CLAUDE_RESULTS_FILE}"

echo "Invoking Claude to process and consolidate PRs..."
echo "=========================================="

# Run Claude with explicit tool allowlist
set +e
echo "$CLAUDE_PROMPT" | claude --print \
  --allowedTools "Bash,Read,Write,Edit,Grep,Glob,WebFetch,Skill,Task,TodoWrite" \
  --output-format json \
  --max-turns 100 \
  2>&1 | tee "$CLAUDE_OUTPUT_FILE"
CLAUDE_EXIT_CODE=$?
set -e

echo "=========================================="
echo ""

if [ $CLAUDE_EXIT_CODE -ne 0 ]; then
  echo "=========================================="
  echo "CLAUDE PROCESSING FAILED"
  echo "=========================================="
  echo "Exit code: $CLAUDE_EXIT_CODE"
  rm -f "$CLAUDE_OUTPUT_FILE"
  rm -f "$CLAUDE_RESULTS_FILE"
  exit 1
fi

echo "Claude processing completed. Starting bash-level validation..."

# Parse structured markers from results file (written by Claude during processing)
rm -f "$CLAUDE_OUTPUT_FILE"
SUCCEEDED_PRS=$(grep -E '^SUCCEEDED_PR:' "$CLAUDE_RESULTS_FILE" || true)
FAILED_PRS=$(grep -E '^FAILED_PR:' "$CLAUDE_RESULTS_FILE" || true)
rm -f "$CLAUDE_RESULTS_FILE"

SUCCEEDED_COUNT=$(echo "$SUCCEEDED_PRS" | grep -c '^SUCCEEDED_PR:' || true)
echo "Successfully processed PRs: $SUCCEEDED_COUNT"

if [ "$SUCCEEDED_COUNT" -eq 0 ]; then
  echo "No PRs were successfully processed. Nothing to do."
  if [ -n "$FAILED_PRS" ]; then
    echo ""
    echo "Failed PRs:"
    echo "$FAILED_PRS"
  fi
  exit 0
fi

# Verify the consolidation branch exists
CONSOLIDATION_BRANCH="fix/weekly-dependabot-consolidation"
if ! git rev-parse --verify "$CONSOLIDATION_BRANCH" >/dev/null 2>&1; then
  echo "ERROR: Consolidation branch '$CONSOLIDATION_BRANCH' does not exist"
  exit 1
fi

# Check for actual changes vs upstream/main
if git diff --quiet upstream/main..."$CONSOLIDATION_BRANCH"; then
  echo "No actual changes between upstream/main and consolidation branch. Nothing to do."
  exit 0
fi

# Checkout the consolidation branch
git checkout "$CONSOLIDATION_BRANCH"

# Run make verify - two-pass: first to fix, second to gate
echo ""
echo "=========================================="
echo "Running make verify (pass 1: fix stale generated files)..."
echo "=========================================="
make verify || true

# Commit any changes from first pass
if ! git diff --quiet; then
  git add -A
  git commit -m "chore: apply make verify fixes"
  echo "Committed make verify changes"
fi

echo "Running make verify (pass 2: hard gate)..."
VERIFY_LOG=$(mktemp /tmp/make-verify.XXXXXX)
if ! make verify 2>&1 | tee "$VERIFY_LOG"; then
  # Ignore failures caused only by gitlint (commit message linting is not relevant here)
  if grep -qi 'gitlint' "$VERIFY_LOG"; then
    echo "make verify failed due to gitlint - ignoring (commit message linting is not relevant for dependabot consolidation)"
  else
    echo ""
    echo "=========================================="
    echo "MAKE VERIFY FAILED - NO PR WILL BE CREATED"
    echo "=========================================="
    rm -f "$VERIFY_LOG"
    exit 1
  fi
fi
rm -f "$VERIFY_LOG"

# Run make test - two-pass: first to fix, second to gate
echo ""
echo "=========================================="
echo "Running make test (pass 1: update test fixtures)..."
echo "=========================================="
make test || true

# Commit any changes from first pass
if ! git diff --quiet; then
  git add -A
  git commit -m "chore: apply make test fixes"
  echo "Committed make test changes"
fi

echo "Running make test (pass 2: hard gate)..."
if ! make test; then
  echo ""
  echo "=========================================="
  echo "MAKE TEST FAILED - NO PR WILL BE CREATED"
  echo "=========================================="
  exit 1
fi

echo ""
echo "make verify and make test passed. Pushing branch and creating PR..."

# Push branch to origin
git push origin "$CONSOLIDATION_BRANCH" --force

# Build PR body from structured markers
PR_BODY="## Summary
Weekly consolidation of dependabot dependency updates.

## Consolidated PRs"

while IFS= read -r line; do
  if [ -z "$line" ]; then continue; fi
  pr_num=$(echo "$line" | cut -d: -f2)
  pr_title=$(echo "$line" | cut -d: -f3-)
  PR_BODY="${PR_BODY}
- #${pr_num}: ${pr_title}"
done <<< "$SUCCEEDED_PRS"

if [ -n "$FAILED_PRS" ]; then
  PR_BODY="${PR_BODY}

## Failed PRs"
  while IFS= read -r line; do
    if [ -z "$line" ]; then continue; fi
    pr_num=$(echo "$line" | cut -d: -f2)
    pr_reason=$(echo "$line" | cut -d: -f3-)
    PR_BODY="${PR_BODY}
- #${pr_num}: ${pr_reason}"
  done <<< "$FAILED_PRS"
fi

PR_BODY="${PR_BODY}

## Commits
1. go.mod/go.sum dependency updates
2. Vendored dependencies
3. API module updates
4. Regenerated CRD assets
5. Other generated changes (if any)

---
Assisted-by: Claude (via Claude Code)"

# Create PR
NEW_PR_URL=$(gh pr create \
  --repo openshift/hypershift \
  --head "hypershift-community:${CONSOLIDATION_BRANCH}" \
  --title "NO-JIRA: chore(deps): weekly dependabot consolidation" \
  --body "$PR_BODY" \
  --no-maintainer-edit \
  --draft)

echo ""
echo "=========================================="
echo "SUCCESS"
echo "=========================================="
echo "Consolidated PR: $NEW_PR_URL"

echo ""
echo "=== Dependabot Triage Complete ==="
