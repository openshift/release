#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== Sippy Jira Agent ==="

# Apply Gangway API overrides (MULTISTAGE_PARAM_OVERRIDE_* prefix)
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_JIRA_ISSUE_KEY:-}" ]]; then
  echo "Applying Gangway override: JIRA_ISSUE_KEY=${MULTISTAGE_PARAM_OVERRIDE_JIRA_ISSUE_KEY}"
  export JIRA_ISSUE_KEY="${MULTISTAGE_PARAM_OVERRIDE_JIRA_ISSUE_KEY}"
fi

if [[ -z "${JIRA_ISSUE_KEY:-}" ]]; then
  echo "ERROR: JIRA_ISSUE_KEY is required. Pass it via Gangway API or set it directly."
  exit 1
fi

if [[ -z "${SIPPY_FORK_REPO:-}" ]]; then
  echo "ERROR: SIPPY_FORK_REPO is required (e.g., 'mybot/sippy')."
  exit 1
fi

echo "Processing issue: ${JIRA_ISSUE_KEY}"
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

# Fetch issue details from Jira REST API (public project, no auth needed)
echo "Fetching issue details from Jira..."
JIRA_URL="https://redhat.atlassian.net/rest/api/2/issue/${JIRA_ISSUE_KEY}?fields=summary,description,status,labels,comment,issuetype,priority"
JIRA_RESPONSE=$(curl -sf --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 5 "${JIRA_URL}") || {
    echo "ERROR: Failed to fetch issue ${JIRA_ISSUE_KEY} from Jira after retries."
    exit 1
}

ISSUE_SUMMARY=$(echo "${JIRA_RESPONSE}" | jq -r '.fields.summary // "No summary"')
ISSUE_DESCRIPTION=$(echo "${JIRA_RESPONSE}" | jq -r '.fields.description // "No description"')
ISSUE_TYPE=$(echo "${JIRA_RESPONSE}" | jq -r '.fields.issuetype.name // "Unknown"')
ISSUE_STATUS=$(echo "${JIRA_RESPONSE}" | jq -r '.fields.status.name // "Unknown"')
ISSUE_COMMENTS=$(echo "${JIRA_RESPONSE}" | jq -r '[.fields.comment.comments[]? | "\(.author.displayName) (\(.created)): \(.body)"] | join("\n---\n")' 2>/dev/null || echo "No comments")

echo "Issue: ${JIRA_ISSUE_KEY}"
echo "Summary: ${ISSUE_SUMMARY}"
echo "Type: ${ISSUE_TYPE}"
echo "Status: ${ISSUE_STATUS}"

# Source is baked into the image at /workspace via ci-operator src input
cd /workspace

git config user.name "openshift-trt"
git config user.email "openshift-trt@redhat.com"

# Set up fork as push target using the GitHub token
set +x
git remote add fork "https://x-access-token:${GITHUB_TOKEN}@github.com/${SIPPY_FORK_REPO}.git"

# Start postgres and redis via the devcontainer's init-services.sh
# Podman is available in this image (composite of devcontainer + podman)
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
    cp "/workspace"/artifacts/* "${ARTIFACT_DIR}/" 2>/dev/null || true
    podman logs sippy-postgres > "${ARTIFACT_DIR}/postgres.log" 2>&1 || true
}
trap copy_artifacts EXIT TERM INT

# Write the Claude prompt to a file
PROMPT_FILE=$(mktemp /tmp/claude-prompt-XXXXXX)
cat > "${PROMPT_FILE}" <<PROMPT_EOF
You are solving a Jira issue for the openshift/sippy repository.

## Issue Details
- **Key**: ${JIRA_ISSUE_KEY}
- **Summary**: ${ISSUE_SUMMARY}
- **Type**: ${ISSUE_TYPE}
- **Status**: ${ISSUE_STATUS}
- **Jira URL**: https://redhat.atlassian.net/browse/${JIRA_ISSUE_KEY}

### Description
${ISSUE_DESCRIPTION}

### Comments
${ISSUE_COMMENTS}

## Instructions
1. Read and understand the issue thoroughly.
2. Explore the codebase to understand the relevant code.
3. Implement the fix or feature described in the issue.
4. Run 'make test' to verify your changes work.
5. Run 'make lint' to check for linting issues.
6. Use the sippy-dev MCP tools to locally run and test your changes:
   - 'sippy_serve' starts the API server (builds automatically)
   - 'sippy_ng_start' starts the React frontend dev server
   - 'run_e2e' runs the end-to-end test suite
7. Run e2e tests using the 'run_e2e' MCP tool. E2e tests MUST pass before creating a PR.
8. Create a feature branch named '${JIRA_ISSUE_KEY}' (lowercase).
9. Commit your changes with a meaningful commit message that references ${JIRA_ISSUE_KEY}.
10. Push the branch to the fork: git push fork HEAD
11. Create a PR from the fork using: gh pr create --repo openshift/sippy --head ${SIPPY_FORK_REPO##*/}:${JIRA_ISSUE_KEY} --title '${JIRA_ISSUE_KEY}: <brief description>' --body '<description of changes>'

## Important
- Always create a regular PR (not a draft) so CI tests run automatically.
- The PR title MUST start with '${JIRA_ISSUE_KEY}: '.
- If you cannot solve the issue, explain why in detail.
- Do not modify CI configuration or generated files.
- Push to the 'fork' remote, NOT 'origin'. A fork remote is pre-configured.
- SECURITY: Do NOT run commands that reveal git credentials like 'git remote -v'.
- PostgreSQL is available at localhost:5432 (user: postgres, no password, trust auth).
- Redis is available at localhost:6379.
- The sippy-dev MCP server provides tools for running the app locally: sippy_serve, sippy_stop, sippy_ng_start, run_e2e, and regression_cache.
- Run './sippy seed-data --init-database' to seed the database before testing.
PROMPT_EOF

echo "Invoking Claude to solve ${JIRA_ISSUE_KEY}..."
mkdir -p "/workspace/artifacts"
ALLOWED_TOOLS="Bash Read Write Edit Grep Glob WebFetch WebSearch"

CLAUDE_EXIT=0
timeout 5400 claude \
    --model "${CLAUDE_MODEL}" \
    --allowedTools "${ALLOWED_TOOLS}" \
    --output-format stream-json \
    --max-turns 100 \
    -p "$(cat "${PROMPT_FILE}")" \
    --verbose 2>&1 | tee "/workspace/artifacts/claude-output.log" || CLAUDE_EXIT=$?

if [[ "${CLAUDE_EXIT}" -eq 124 ]]; then
    echo "Claude timed out. Nudging to wrap up..."
    timeout 600 claude \
        --model "${CLAUDE_MODEL}" \
        --continue \
        --allowedTools "${ALLOWED_TOOLS}" \
        --output-format stream-json \
        --max-turns 10 \
        -p "You hit the timeout. Please wrap up immediately: commit whatever you have, push, and create the PR now." \
        --verbose 2>&1 | tee -a "/workspace/artifacts/claude-output.log" || true
fi

# Check if a PR was created
PR_URL=$(grep -o 'https://github.com/openshift/sippy/pull/[0-9]*' "/workspace/artifacts/claude-output.log" | head -1 || echo "")
if [[ -z "${PR_URL}" ]]; then
    echo "Warning: No PR URL found in output."
    echo "=== Sippy Jira Agent Complete ==="
    exit 0
fi

PR_NUM=$(echo "${PR_URL}" | grep -o '[0-9]*$')
echo "PR created: ${PR_URL} (#${PR_NUM})"

# Poll for review comments (e.g. CodeRabbit) for up to 1 hour after PR creation
echo ""
echo "=== Watching PR #${PR_NUM} for review comments (up to 1 hour) ==="
PR_CREATED_AT=$(date +%s)
REVIEW_ROUND=0

for i in $(seq 1 6); do
    echo "Waiting 10 minutes before checking for comments (check $i/6)..."
    sleep 600

    COMMENTS_JSON=$(gh api "repos/openshift/sippy/pulls/${PR_NUM}/comments" --paginate 2>/dev/null || echo "[]")
    REVIEWS_JSON=$(gh api "repos/openshift/sippy/pulls/${PR_NUM}/reviews" --paginate 2>/dev/null || echo "[]")

    NEW_REVIEW_COMMENTS=$(echo "${COMMENTS_JSON}" | jq --arg since "${PR_CREATED_AT}" \
        '[.[] | select((.created_at | fromdateiso8601) > ($since | tonumber))] | length' 2>/dev/null || echo "0")
    NEW_REVIEWS=$(echo "${REVIEWS_JSON}" | jq --arg since "${PR_CREATED_AT}" \
        '[.[] | select((.submitted_at | fromdateiso8601) > ($since | tonumber)) | select(.state != "APPROVED" and .state != "PENDING")] | length' 2>/dev/null || echo "0")

    TOTAL_NEW=$(( NEW_REVIEW_COMMENTS + NEW_REVIEWS ))
    echo "Found ${TOTAL_NEW} new comment(s)/review(s) since PR creation."

    if [[ "${TOTAL_NEW}" -gt 0 ]]; then
        REVIEW_ROUND=$(( REVIEW_ROUND + 1 ))
        echo "Addressing review comments (round ${REVIEW_ROUND})..."

        REVIEW_BODY=$(echo "${COMMENTS_JSON}" | jq -r '.[] | "**\(.user.login)** on `\(.path // "general")`:\n\(.body)\n---"' 2>/dev/null || echo "")
        REVIEW_SUMMARY=$(echo "${REVIEWS_JSON}" | jq -r '.[] | select(.state != "APPROVED" and .state != "PENDING") | "**\(.user.login)** (\(.state)):\n\(.body)\n---"' 2>/dev/null || echo "")

        timeout 1800 claude \
            --model "${CLAUDE_MODEL}" \
            --continue \
            --allowedTools "${ALLOWED_TOOLS}" \
            --output-format stream-json \
            --max-turns 50 \
            -p "Review comments have been posted on the PR. Address all of them, then push your fixes to the fork.

${REVIEW_BODY}
${REVIEW_SUMMARY}

After fixing, run 'make test' and 'make lint' to verify. Then run e2e tests using the 'run_e2e' MCP tool — e2e tests MUST pass before pushing. Then push: git push fork HEAD" \
            --verbose 2>&1 | tee -a "/workspace/artifacts/claude-output.log" || true

        # Reset the timestamp so we only pick up comments newer than this round
        PR_CREATED_AT=$(date +%s)
    fi
done

echo "=== Sippy Jira Agent Complete ==="
