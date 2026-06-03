#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== Sippy PR Followup Agent ==="

# Apply Gangway API overrides (MULTISTAGE_PARAM_OVERRIDE_* prefix)
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_JIRA_ISSUE_KEY:-}" ]]; then
  echo "Applying Gangway override: JIRA_ISSUE_KEY=${MULTISTAGE_PARAM_OVERRIDE_JIRA_ISSUE_KEY}"
  export JIRA_ISSUE_KEY="${MULTISTAGE_PARAM_OVERRIDE_JIRA_ISSUE_KEY}"
fi

if [[ -z "${JIRA_ISSUE_KEY:-}" ]]; then
  echo "ERROR: JIRA_ISSUE_KEY is required. Pass it via Gangway API or set it directly."
  exit 1
fi

echo "Following up on issue: ${JIRA_ISSUE_KEY}"
echo "Model: ${CLAUDE_MODEL}"
echo "Fork: ${SIPPY_FORK_REPO}"

# Load GitHub token with xtrace disabled to prevent leaking credentials
set +x
if [[ -f "${GITHUB_TOKEN_PATH}" ]]; then
    export GITHUB_TOKEN
    GITHUB_TOKEN=$(cat "${GITHUB_TOKEN_PATH}")
    echo "GitHub token loaded."
else
    echo "ERROR: GitHub token not found at ${GITHUB_TOKEN_PATH}."
    exit 1
fi

# Find the PR associated with this Jira issue
echo "Searching for PR associated with ${JIRA_ISSUE_KEY}..."
PR_JSON=$(gh pr list --repo openshift/sippy --state open --search "${JIRA_ISSUE_KEY}" --json number,title,headRefName,url --limit 5 2>/dev/null || echo "[]")
PR_COUNT=$(echo "${PR_JSON}" | jq 'length')

if [[ "${PR_COUNT}" -eq 0 ]]; then
    echo "No open PR found for ${JIRA_ISSUE_KEY}. Searching closed PRs..."
    PR_JSON=$(gh pr list --repo openshift/sippy --state closed --search "${JIRA_ISSUE_KEY}" --json number,title,headRefName,url --limit 5 2>/dev/null || echo "[]")
    PR_COUNT=$(echo "${PR_JSON}" | jq 'length')
fi

if [[ "${PR_COUNT}" -eq 0 ]]; then
    echo "ERROR: No PR found for ${JIRA_ISSUE_KEY}."
    exit 1
fi

# Use the first matching PR
PR_NUM=$(echo "${PR_JSON}" | jq -r '.[0].number')
PR_TITLE=$(echo "${PR_JSON}" | jq -r '.[0].title')
PR_BRANCH=$(echo "${PR_JSON}" | jq -r '.[0].headRefName')
PR_URL=$(echo "${PR_JSON}" | jq -r '.[0].url')

echo "Found PR #${PR_NUM}: ${PR_TITLE}"
echo "Branch: ${PR_BRANCH}"
echo "URL: ${PR_URL}"

# Fetch review comments and reviews
echo "Fetching review comments..."
COMMENTS_JSON=$(gh api "repos/openshift/sippy/pulls/${PR_NUM}/comments" --paginate 2>/dev/null || echo "[]")
REVIEWS_JSON=$(gh api "repos/openshift/sippy/pulls/${PR_NUM}/reviews" --paginate 2>/dev/null || echo "[]")

COMMENT_COUNT=$(echo "${COMMENTS_JSON}" | jq 'length')
REVIEW_COUNT=$(echo "${REVIEWS_JSON}" | jq '[.[] | select(.state != "APPROVED" and .state != "PENDING")] | length')
TOTAL=$(( COMMENT_COUNT + REVIEW_COUNT ))

echo "Found ${COMMENT_COUNT} inline comment(s) and ${REVIEW_COUNT} review(s) to address."

if [[ "${TOTAL}" -eq 0 ]]; then
    echo "No review comments to address. Nothing to do."
    exit 0
fi

# Source is baked into the image at /workspace via ci-operator src input
cd /workspace

git config user.name "openshift-trt"
git config user.email "openshift-trt@redhat.com"

# Set up fork remote
set +x
git remote add fork "https://x-access-token:${GITHUB_TOKEN}@github.com/${SIPPY_FORK_REPO}.git"

# Fetch and check out the PR branch from the fork
echo "Checking out PR branch ${PR_BRANCH}..."
git fetch fork "${PR_BRANCH}"
git checkout -b "${PR_BRANCH}" "fork/${PR_BRANCH}"

# Start postgres and redis via the devcontainer's init-services.sh
echo "Starting services..."
export SIPPY_SEED_DATABASE_DSN="postgresql://postgres@localhost:5432/postgres?sslmode=disable"
export SIPPY_PRODLIKE_DATABASE_DSN="postgresql://postgres@localhost:5432/prodlike?sslmode=disable"
.devcontainer/init-services.sh

# Run the devcontainer's post-create.sh to install Claude, build sippy, seed DB
echo "Running post-create setup..."
.devcontainer/post-create.sh

# Ensure artifacts are copied even on early exit
copy_artifacts() {
    echo "Copying artifacts..."
    cp /workspace/artifacts/* "${ARTIFACT_DIR}/" 2>/dev/null || true
}
trap copy_artifacts EXIT TERM INT

# Format the review comments for Claude
REVIEW_BODY=$(echo "${COMMENTS_JSON}" | jq -r '.[] | "**\(.user.login)** on `\(.path)`:\n\(.body)\n---"' 2>/dev/null || echo "")
REVIEW_SUMMARY=$(echo "${REVIEWS_JSON}" | jq -r '.[] | select(.state != "APPROVED" and .state != "PENDING") | "**\(.user.login)** (\(.state)):\n\(.body)\n---"' 2>/dev/null || echo "")

# Write the prompt
PROMPT_FILE=$(mktemp /tmp/claude-prompt-XXXXXX)
cat > "${PROMPT_FILE}" <<PROMPT_EOF
You are following up on PR #${PR_NUM} for Jira issue ${JIRA_ISSUE_KEY} in the openshift/sippy repository.

## PR Details
- **PR**: #${PR_NUM} — ${PR_TITLE}
- **URL**: ${PR_URL}
- **Branch**: ${PR_BRANCH}
- **Jira**: https://redhat.atlassian.net/browse/${JIRA_ISSUE_KEY}

## Review Comments to Address

### Inline Comments
${REVIEW_BODY:-No inline comments.}

### Reviews
${REVIEW_SUMMARY:-No reviews.}

## Instructions
1. Read and understand each review comment.
2. Explore the relevant code to understand the context.
3. Address each comment by making the appropriate code changes.
4. Run 'make test' and 'make lint' to verify your changes.
5. Run e2e tests using the 'run_e2e' MCP tool. E2e tests MUST pass before pushing.
6. Commit your fixes with a message referencing the review feedback.
7. Push to the fork: git push fork HEAD

DO NOT push until e2e tests pass.

## Important
- Address ALL review comments, not just some.
- If a comment is already resolved or not actionable, explain why in the commit message.
- Do not modify CI configuration or generated files.
- Push to the 'fork' remote, NOT 'origin'.
- SECURITY: Do NOT run commands that reveal git credentials like 'git remote -v'.
- PostgreSQL is available at localhost:5432 (user: postgres, no password, trust auth).
- Redis is available at localhost:6379.
- The sippy-dev MCP server provides tools: sippy_serve, sippy_stop, sippy_ng_start, run_e2e.
PROMPT_EOF

echo "Invoking Claude to address review comments..."
mkdir -p /workspace/artifacts
ALLOWED_TOOLS="Bash Read Write Edit Grep Glob WebFetch WebSearch"

CLAUDE_EXIT=0
timeout 5400 claude \
    --model "${CLAUDE_MODEL}" \
    --allowedTools "${ALLOWED_TOOLS}" \
    --output-format stream-json \
    --max-turns 100 \
    -p "$(cat "${PROMPT_FILE}")" \
    --verbose 2>&1 | tee /workspace/artifacts/claude-output.log || CLAUDE_EXIT=$?

if [[ "${CLAUDE_EXIT}" -eq 124 ]]; then
    echo "Claude timed out. Nudging to wrap up..."
    timeout 600 claude \
        --model "${CLAUDE_MODEL}" \
        --continue \
        --allowedTools "${ALLOWED_TOOLS}" \
        --output-format stream-json \
        --max-turns 10 \
        -p "You hit the timeout. Please commit and push whatever fixes you have now: git push fork HEAD" \
        --verbose 2>&1 | tee -a /workspace/artifacts/claude-output.log || true
fi

echo "=== Sippy PR Followup Agent Complete ==="
