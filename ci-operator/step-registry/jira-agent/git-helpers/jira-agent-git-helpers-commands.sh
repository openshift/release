#!/bin/bash
set -euo pipefail

cat > "${SHARED_DIR}/git-helpers.sh" << 'HEREDOC_EOF'
#!/bin/bash
# Git and GitHub App token helper functions for jira-agent.
#
# Usage:
#   source "${SHARED_DIR}/git-helpers.sh"
#
# Functions:
#   load_github_app_credentials   - Validate and load credential files
#   generate_and_configure_tokens - Generate initial tokens, configure git
#   refresh_fork_token            - Refresh fork GitHub App token
#   refresh_upstream_token        - Refresh upstream GitHub App token
#   refresh_all_tokens            - Refresh both fork and upstream tokens
#   sync_fork_with_upstream       - Sync fork main with upstream main
#   check_branch_changes          - Detect code changes on current branch

GITHUB_APP_CREDS_DIR="/var/run/claude-code-service-account"

# Validate and load GitHub App credential files.
# Sets: INSTALLATION_ID_FORK, INSTALLATION_ID_UPSTREAM
# Requires: FORK_INSTALL_ID_KEY, UPSTREAM_INSTALL_ID_KEY
load_github_app_credentials() {
  echo "Loading GitHub App credentials..."

  local app_id_file="${GITHUB_APP_CREDS_DIR}/app-id"
  local installation_id_file="${GITHUB_APP_CREDS_DIR}/${FORK_INSTALL_ID_KEY}"
  local private_key_file="${GITHUB_APP_CREDS_DIR}/private-key"
  local installation_id_upstream_file="${GITHUB_APP_CREDS_DIR}/${UPSTREAM_INSTALL_ID_KEY}"

  if [ ! -f "$app_id_file" ] || [ ! -f "$installation_id_file" ] || [ ! -f "$private_key_file" ] || [ ! -f "$installation_id_upstream_file" ]; then
    echo "GitHub App credentials not yet available in ${GITHUB_APP_CREDS_DIR}"
    echo "Available files:"
    ls -la "${GITHUB_APP_CREDS_DIR}/" || echo "Directory does not exist"
    echo ""
    echo "Waiting for Vault secretsync to complete. The following keys are required:"
    echo "  - app-id"
    echo "  - ${FORK_INSTALL_ID_KEY} (for fork)"
    echo "  - ${UPSTREAM_INSTALL_ID_KEY} (for upstream)"
    echo "  - private-key"
    echo ""
    echo "Exiting gracefully. Re-run once secrets are synced."
    echo "no_credentials" > "${SHARED_DIR}/processed-issues.txt"
    exit 0
  fi

  [[ $- == *x* ]] && local _was_tracing=true || local _was_tracing=false
  set +x

  INSTALLATION_ID_FORK=$(cat "$installation_id_file")
  INSTALLATION_ID_UPSTREAM=$(cat "$installation_id_upstream_file")

  $_was_tracing && set -x || true
}

# Generate initial GitHub App tokens and configure git credentials.
# Sets: GITHUB_TOKEN_FORK, GITHUB_TOKEN_UPSTREAM, GITHUB_TOKEN (exported)
# Requires: INSTALLATION_ID_FORK, INSTALLATION_ID_UPSTREAM, generate_github_token()
generate_and_configure_tokens() {
  echo "Generating GitHub App tokens..."

  [[ $- == *x* ]] && local _was_tracing=true || local _was_tracing=false
  set +x

  echo "Generating GitHub App token for fork..."
  GITHUB_TOKEN_FORK=$(generate_github_token "$INSTALLATION_ID_FORK")
  if [ -z "$GITHUB_TOKEN_FORK" ] || [ "$GITHUB_TOKEN_FORK" = "null" ]; then
    echo "ERROR: Failed to generate GitHub App token for fork"
    $_was_tracing && set -x || true
    exit 1
  fi
  echo "Fork token generated successfully"

  echo "Generating GitHub App token for upstream..."
  GITHUB_TOKEN_UPSTREAM=$(generate_github_token "$INSTALLATION_ID_UPSTREAM")
  if [ -z "$GITHUB_TOKEN_UPSTREAM" ] || [ "$GITHUB_TOKEN_UPSTREAM" = "null" ]; then
    echo "ERROR: Failed to generate GitHub App token for upstream"
    $_was_tracing && set -x || true
    exit 1
  fi
  echo "Upstream token generated successfully"

  git config --global credential.helper "!f() { echo username=x-access-token; echo password=${GITHUB_TOKEN_FORK}; }; f"
  export GITHUB_TOKEN="$GITHUB_TOKEN_UPSTREAM"
  echo "GitHub App tokens configured successfully"

  $_was_tracing && set -x || true
}

# Refresh the fork GitHub App token and update git credential helper.
# Updates: GITHUB_TOKEN_FORK
refresh_fork_token() {
  echo "Refreshing GitHub App token for fork..."
  [[ $- == *x* ]] && local _was_tracing=true || local _was_tracing=false
  set +x
  local _new_token
  if _new_token=$(generate_github_token "$INSTALLATION_ID_FORK") \
    && [ -n "$_new_token" ] && [ "$_new_token" != "null" ]; then
    GITHUB_TOKEN_FORK="$_new_token"
    git config --global credential.helper "!f() { echo username=x-access-token; echo password=${GITHUB_TOKEN_FORK}; }; f"
    echo "Fork token refreshed"
  else
    echo "ERROR: Failed to refresh GitHub App token for fork — continuing with previous token"
  fi
  $_was_tracing && set -x || true
}

# Refresh the upstream GitHub App token and update GITHUB_TOKEN.
# Updates: GITHUB_TOKEN_UPSTREAM, GITHUB_TOKEN (exported)
refresh_upstream_token() {
  echo "Refreshing GitHub App token for upstream..."
  [[ $- == *x* ]] && local _was_tracing=true || local _was_tracing=false
  set +x
  local _new_token
  if _new_token=$(generate_github_token "$INSTALLATION_ID_UPSTREAM") \
    && [ -n "$_new_token" ] && [ "$_new_token" != "null" ]; then
    GITHUB_TOKEN_UPSTREAM="$_new_token"
    export GITHUB_TOKEN="$GITHUB_TOKEN_UPSTREAM"
    echo "Upstream token refreshed"
  else
    echo "ERROR: Failed to refresh GitHub App token for upstream — continuing with previous token"
  fi
  $_was_tracing && set -x || true
}

# Refresh both fork and upstream GitHub App tokens.
refresh_all_tokens() {
  refresh_fork_token
  refresh_upstream_token
}

# Sync fork main branch with upstream main.
# Must be called from inside the repo working directory.
# Requires: JIRA_AGENT_UPSTREAM_REPO
sync_fork_with_upstream() {
  echo "Syncing fork with upstream ${JIRA_AGENT_UPSTREAM_REPO}..."
  git config user.name "OpenShift CI Bot"
  git config user.email "ci-bot@redhat.com"
  git remote add upstream "https://github.com/${JIRA_AGENT_UPSTREAM_REPO}.git"
  git fetch upstream main
  git checkout main
  git rebase upstream/main
  echo "Fork synced with upstream successfully"
}

# Check if code changes exist on the current branch vs main.
# Sets: HAS_CODE_CHANGES (true/false), BRANCH_NAME, PR_URL (empty)
check_branch_changes() {
  BRANCH_NAME=$(git branch --show-current)
  HAS_CODE_CHANGES=false
  PR_URL=""

  if [ "$BRANCH_NAME" != "main" ] && [ "$BRANCH_NAME" != "master" ] && [ -n "$BRANCH_NAME" ]; then
    local diff_files
    diff_files=$(git diff main...HEAD --name-only 2>/dev/null || echo "")
    if [ -n "$diff_files" ]; then
      HAS_CODE_CHANGES=true
      echo "Code changes detected on branch $BRANCH_NAME"
    fi
  fi
}

# Reset working tree to upstream main for a clean starting state between issues.
reset_to_main() {
  git checkout main 2>/dev/null || true
  git reset --hard upstream/main 2>/dev/null || true
}

# Append a jira-agent report link to a PR description.
# Arguments: <pr_number> <issue_key>
# Requires: JIRA_AGENT_UPSTREAM_REPO, JIRA_BASE_URL, BUILD_ID, JOB_NAME, JOB_TYPE
append_report_link_to_pr() {
  local pr_num=$1 issue_key=$2

  local report_url=""
  if [ -n "${BUILD_ID:-}" ] && [ -n "${JOB_NAME:-}" ]; then
    if [ "${JOB_TYPE:-}" = "periodic" ]; then
      report_url="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/logs/${JOB_NAME}/${BUILD_ID}/artifacts/periodic-jira-agent/jira-agent-report/artifacts/jira-agent-report.html"
    else
      report_url="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/pr-logs/pull/openshift_release/${PULL_NUMBER:-0}/${JOB_NAME}/${BUILD_ID}/artifacts/periodic-jira-agent/jira-agent-report/artifacts/jira-agent-report.html"
    fi
  fi

  if [ -z "$report_url" ]; then
    return 0
  fi

  echo "Appending report link to PR #${pr_num} description..."
  local current_body
  current_body=$(gh pr view "$pr_num" --repo "${JIRA_AGENT_UPSTREAM_REPO}" --json body -q .body 2>/dev/null || echo "")
  local report_section="---

> **Note:** This PR was auto-generated by the jira-agent periodic CI job in response to [${issue_key}](${JIRA_BASE_URL}/browse/${issue_key}). See the [full report](${report_url}) for token usage, cost breakdown, and detailed phase output."
  local updated_body="${current_body}

${report_section}"
  gh pr edit "$pr_num" --repo "${JIRA_AGENT_UPSTREAM_REPO}" --body "$updated_body" 2>/dev/null \
    || echo "Warning: Failed to update PR #${pr_num} description"
}
HEREDOC_EOF

echo "git-helpers.sh written to SHARED_DIR"
