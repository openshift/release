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
   Run e2e tests before committing to catch integration issues.
7. Create a feature branch named '${JIRA_ISSUE_KEY}' (lowercase).
8. Commit your changes with a meaningful commit message that references ${JIRA_ISSUE_KEY}.
9. Push the branch to the fork: git push fork HEAD
10. Create a PR from the fork using: gh pr create --repo openshift/sippy --head ${SIPPY_FORK_REPO##*/}:${JIRA_ISSUE_KEY} --title '${JIRA_ISSUE_KEY}: <brief description>' --body '<description of changes>'

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
if [[ -n "${PR_URL}" ]]; then
    echo "PR created: ${PR_URL}"
else
    echo "Warning: No PR URL found in output."
fi

echo "=== Sippy Jira Agent Complete ==="
