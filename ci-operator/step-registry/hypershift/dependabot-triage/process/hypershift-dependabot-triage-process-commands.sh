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
  if echo "$pr_diff" | grep -vE '// indirect' | grep -qE '^\+[^+].*\b(k8s\.io|sigs\.k8s\.io)/'; then
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
   - Run: `make verify 2>&1 | tee /tmp/make-verify-pr.log; VERIFY_EXIT=${PIPESTATUS[0]}`
   - If VERIFY_EXIT is non-zero, determine if gitlint is the ONLY failure by running:
     `NON_GITLINT=$(grep 'make:.*\*\*\*' /tmp/make-verify-pr.log | grep -vi 'gitlint' || true)`
   - If NON_GITLINT is empty: gitlint is the only failure, ignore it and continue
   - If NON_GITLINT is NOT empty: there are real failures. Record PR as failed with the NON_GITLINT output as reason, run `git reset --hard <saved_sha> && git clean -fd` to fully revert all changes, continue to next PR

4. **Run UPDATE=true make test**: Update test fixtures
   - If make test fails: record PR as failed with reason, run `git reset --hard <saved_sha> && git clean -fd` to fully revert all changes, continue to next PR

5. **Commit generated changes**: Commit any files changed by make verify/test
   - Use message: "chore: regenerate files for PR #<number>"

6. **Record success**: Add this PR to succeeded_prs list

7. **Move to next PR**: Repeat steps 1-6 for the next PR

### Phase 3: Output Results and Exit

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
  --model "$CLAUDE_MODEL" \
  --allowedTools "Bash,Read,Write,Edit,Grep,Glob,WebFetch,Skill,Task,TodoWrite" \
  --verbose \
  --output-format stream-json \
  --max-turns 100 \
  2> "/tmp/claude-dependabot-output.log" \
  | tee "$CLAUDE_OUTPUT_FILE"
CLAUDE_EXIT_CODE=$?
set -e

echo "=========================================="
echo ""

# Extract token usage from stream-json result message (includes subagent costs)
grep '"type":"result"' "$CLAUDE_OUTPUT_FILE" \
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
    }' > "${SHARED_DIR}/claude-dependabot-tokens.json" 2>/dev/null \
  || echo '{"total_cost_usd":0,"duration_ms":0,"num_turns":0,"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"model_usage":{},"model":"unknown"}' > "${SHARED_DIR}/claude-dependabot-tokens.json"
echo "Token usage: $(cat "${SHARED_DIR}/claude-dependabot-tokens.json")"

# Extract Claude text output and tool usage summaries
jq -r '
  if .type == "assistant" then
    .message.content[]? |
    if .type == "text" then
      .text // empty
    elif .type == "tool_use" and .name == "Bash" then
      "\n$ " + (.input.description // .input.command[:80]) + ""
    else empty end
  elif .type == "user" then
    .message.content[]? |
    if .type == "tool_result" then
      (.content // "" | split("\n") | first // "") + ""
    else empty end
  else empty end
' "$CLAUDE_OUTPUT_FILE" > "${SHARED_DIR}/claude-dependabot-output-text.txt" 2>/dev/null || true
jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | "\(.name): \(.input | keys | join(", "))"' "$CLAUDE_OUTPUT_FILE" 2>/dev/null | sort | uniq -c | sort -rn > "${SHARED_DIR}/claude-dependabot-output-tools.txt" 2>/dev/null || true

if [ $CLAUDE_EXIT_CODE -ne 0 ]; then
  echo "=========================================="
  echo "CLAUDE PROCESSING FAILED"
  echo "=========================================="
  echo "Exit code: $CLAUDE_EXIT_CODE"
  echo ""
  echo "Claude stderr log:"
  cat "/tmp/claude-dependabot-output.log" 2>/dev/null || echo "(no stderr log found)"
  cp "/tmp/claude-dependabot-output.log" "${ARTIFACT_DIR}/claude-stderr.log" 2>/dev/null || true
  rm -f "$CLAUDE_OUTPUT_FILE"
  rm -f "$CLAUDE_RESULTS_FILE"
  exit 1
fi

echo "Claude processing completed. Starting bash-level validation..."

# Parse structured markers from results file (written by Claude during processing)
rm -f "$CLAUDE_OUTPUT_FILE"
SUCCEEDED_PRS=$(grep -E '^SUCCEEDED_PR:' "$CLAUDE_RESULTS_FILE" || true)
FAILED_PRS=$(grep -E '^FAILED_PR:' "$CLAUDE_RESULTS_FILE" || true)
# Copy results to SHARED_DIR for report step
cp "$CLAUDE_RESULTS_FILE" "${SHARED_DIR}/dependabot-results.txt"
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

# Reorganize commits into logical groups
echo ""
echo "=========================================="
echo "Reorganizing commits into logical groups..."
echo "=========================================="
MERGE_BASE=$(git merge-base upstream/main HEAD)
echo "Merge base: $MERGE_BASE"
echo "Files changed: $(git diff --stat "$MERGE_BASE" HEAD | tail -1)"

# Mixed reset to merge base - keeps working tree, unstages everything
git reset "$MERGE_BASE"

# Commit 1: Root module go.mod/go.sum
git add go.mod go.sum 2>/dev/null || true
git diff --cached --quiet 2>/dev/null || git commit -m "$(cat <<'CMSG'
chore(deps): update root module dependencies

Weekly dependabot dependency consolidation.
CMSG
)"

# Commit 2: Root vendor/
git add vendor/ 2>/dev/null || true
git diff --cached --quiet 2>/dev/null || git commit -m "$(cat <<'CMSG'
chore(deps): update vendored dependencies

Vendor updates for root module dependency changes.
CMSG
)"

# Commit 3: api/ module go.mod/go.sum
git add api/go.mod api/go.sum 2>/dev/null || true
git diff --cached --quiet 2>/dev/null || git commit -m "$(cat <<'CMSG'
chore(deps): update API module dependencies

Weekly dependabot dependency consolidation for api/ module.
CMSG
)"

# Commit 4: api/ vendor
git add api/vendor/ 2>/dev/null || true
git diff --cached --quiet 2>/dev/null || git commit -m "$(cat <<'CMSG'
chore(deps): update API vendored dependencies

Vendor updates for api/ module dependency changes.
CMSG
)"

# Commit 5: hack/tools/ module go.mod/go.sum
git add hack/tools/go.mod hack/tools/go.sum 2>/dev/null || true
git diff --cached --quiet 2>/dev/null || git commit -m "$(cat <<'CMSG'
chore(deps): update hack/tools module dependencies

Weekly dependabot dependency consolidation for hack/tools/ module.
CMSG
)"

# Commit 6: hack/tools/ vendor
git add hack/tools/vendor/ 2>/dev/null || true
git diff --cached --quiet 2>/dev/null || git commit -m "$(cat <<'CMSG'
chore(deps): update hack/tools vendored dependencies

Vendor updates for hack/tools/ module dependency changes.
CMSG
)"

# Commit 7: Regenerated CRD assets
git add cmd/install/assets/ 2>/dev/null || true
git diff --cached --quiet 2>/dev/null || git commit -m "$(cat <<'CMSG'
chore: regenerate CRD assets

Regenerated CRD manifests after dependency updates.
CMSG
)"

# Commit 8: Everything else
git add -A
if ! git diff --cached --quiet 2>/dev/null; then
  echo "Remaining files in catch-all commit:"
  git diff --cached --stat
fi
git diff --cached --quiet 2>/dev/null || git commit -m "$(cat <<'CMSG'
chore: update remaining generated files

Additional generated file updates from dependency changes.
CMSG
)"

echo "Reorganization complete. Commits:"
git log --oneline "$MERGE_BASE"..HEAD
echo ""

# Run make verify - two-pass: first to fix, second to gate
echo ""
echo "=========================================="
echo "Running make verify (pass 1: fix stale generated files)..."
echo "=========================================="
make verify || true

# Commit any changes from first pass
if ! git diff --quiet; then
  git add -A
  git commit -m "$(cat <<'CMSG'
chore: apply make verify fixes

Auto-generated changes from make verify on consolidated branch.
CMSG
)"
  echo "Committed make verify changes"
fi

echo "Running make verify (pass 2: hard gate)..."
VERIFY_LOG=$(mktemp /tmp/make-verify.XXXXXX)
if ! make verify 2>&1 | tee "$VERIFY_LOG"; then
  # Check if any make target OTHER than run-gitlint failed
  # make failure lines look like: make: *** [Makefile:394: run-gitlint] Error 254
  NON_GITLINT_FAILURES=$(grep 'make:.*\*\*\*' "$VERIFY_LOG" | grep -vi 'gitlint' || true)
  if [ -z "$NON_GITLINT_FAILURES" ]; then
    echo "make verify failed due to gitlint only - ignoring"
  else
    echo ""
    echo "=========================================="
    echo "MAKE VERIFY FAILED - NO PR WILL BE CREATED"
    echo "=========================================="
    echo "Non-gitlint make target failures:"
    echo "$NON_GITLINT_FAILURES"
    cp "$VERIFY_LOG" "${ARTIFACT_DIR}/make-verify-failure.log" 2>/dev/null || true
    rm -f "$VERIFY_LOG"
    echo "FINAL_VERIFY_FAILED:make verify failed on consolidation branch" >> "${SHARED_DIR}/dependabot-results.txt"
    exit 0
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
  git commit -m "$(cat <<'CMSG'
chore: apply make test fixes

Auto-generated changes from make test on consolidated branch.
CMSG
)"
  echo "Committed make test changes"
fi

echo "Running make test (pass 2: hard gate)..."
if ! make test; then
  echo ""
  echo "=========================================="
  echo "MAKE TEST FAILED - NO PR WILL BE CREATED"
  echo "=========================================="
  echo "FINAL_TEST_FAILED:make test failed on consolidation branch" >> "${SHARED_DIR}/dependabot-results.txt"
  exit 0
fi

echo ""
echo "make verify and make test passed. Pushing branch and creating PR..."

# Refresh GitHub App tokens (originals likely expired after long processing)
echo "Refreshing GitHub App tokens..."
GITHUB_TOKEN_FORK=$(generate_github_token "$INSTALLATION_ID_FORK")
if [ -z "$GITHUB_TOKEN_FORK" ] || [ "$GITHUB_TOKEN_FORK" = "null" ]; then
  echo "ERROR: Failed to refresh GitHub App token for fork"
  exit 1
fi
git config --global credential.helper "!f() { echo username=x-access-token; echo password=${GITHUB_TOKEN_FORK}; }; f"

GITHUB_TOKEN_UPSTREAM=$(generate_github_token "$INSTALLATION_ID_UPSTREAM")
if [ -z "$GITHUB_TOKEN_UPSTREAM" ] || [ "$GITHUB_TOKEN_UPSTREAM" = "null" ]; then
  echo "ERROR: Failed to refresh GitHub App token for upstream"
  exit 1
fi
export GITHUB_TOKEN="$GITHUB_TOKEN_UPSTREAM"
echo "Tokens refreshed successfully"

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

MERGE_BASE_PR=$(git merge-base upstream/main HEAD)
COMMIT_LIST=""
COMMIT_NUM=0
while IFS= read -r commit_msg; do
  COMMIT_NUM=$((COMMIT_NUM + 1))
  COMMIT_LIST="${COMMIT_LIST}
${COMMIT_NUM}. ${commit_msg}"
done < <(git log --format='%s' --reverse "$MERGE_BASE_PR"..HEAD)

PR_BODY="${PR_BODY}

## Commits${COMMIT_LIST}

---
Assisted-by: Claude (via Claude Code)"

# Create PR
NEW_PR_URL=$(gh pr create \
  --repo openshift/hypershift \
  --head "hypershift-community:${CONSOLIDATION_BRANCH}" \
  --title "NO-JIRA: chore(deps): weekly dependabot consolidation" \
  --body "$PR_BODY" \
  --no-maintainer-edit)

# Save consolidated PR URL for report step
echo "$NEW_PR_URL" > "${SHARED_DIR}/consolidated-pr-url.txt"

# Append report link to PR description
PR_NUM=$(echo "$NEW_PR_URL" | grep -o '[0-9]*$' || true)
if [ -n "$PR_NUM" ] && [ -n "${BUILD_ID:-}" ] && [ -n "${JOB_NAME:-}" ]; then
  REPORT_URL=""
  if [ "${JOB_TYPE:-}" = "periodic" ]; then
    REPORT_URL="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/logs/${JOB_NAME}/${BUILD_ID}/artifacts/dependabot-triage/hypershift-dependabot-triage-report/artifacts/dependabot-triage-report.html"
  else
    REPORT_URL="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/pr-logs/pull/openshift_release/${PULL_NUMBER:-0}/${JOB_NAME}/${BUILD_ID}/artifacts/dependabot-triage/hypershift-dependabot-triage-report/artifacts/dependabot-triage-report.html"
  fi
  echo "Appending report link to PR #${PR_NUM} description..."
  CURRENT_BODY=$(gh pr view "$PR_NUM" --repo openshift/hypershift --json body -q .body 2>/dev/null || echo "")
  REPORT_SECTION="---

> **Note:** This PR was auto-generated by the [dependabot-triage](https://github.com/openshift/release/tree/main/ci-operator/step-registry/hypershift/dependabot-triage) periodic CI job. See the [full report](${REPORT_URL}) for token usage, cost breakdown, and detailed output."
  UPDATED_BODY="${CURRENT_BODY}

${REPORT_SECTION}"
  gh pr edit "$PR_NUM" --repo openshift/hypershift --body "$UPDATED_BODY" 2>/dev/null || echo "Warning: Failed to update PR #${PR_NUM} description"
fi

echo ""
echo "=========================================="
echo "SUCCESS"
echo "=========================================="
echo "Consolidated PR: $NEW_PR_URL"

echo ""
echo "=== Dependabot Triage Complete ==="
