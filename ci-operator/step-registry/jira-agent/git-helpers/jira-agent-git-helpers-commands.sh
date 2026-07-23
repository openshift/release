#!/bin/bash
set -euo pipefail

cat > "${SHARED_DIR}/git-helpers.sh" << 'HEREDOC_EOF'
#!/bin/bash
# Git and GitHub token helper functions for jira-agent.
#
# Supports two auth modes (JIRA_AGENT_AUTH_MODE):
#   "app"  — GitHub App with separate fork/upstream installation tokens (default)
#   "pat"  — Classic PAT for fork creation, push, and PR creation
#
# Usage:
#   source "${SHARED_DIR}/git-helpers.sh"
#
# Functions:
#   load_credentials              - Load credentials (dispatches by auth mode)
#   ensure_fork_exists            - Create fork if needed (PAT mode)
#   refresh_fork_token            - Refresh fork token (no-op in PAT mode)
#   refresh_upstream_token        - Refresh upstream token (no-op in PAT mode)
#   refresh_all_tokens            - Refresh all tokens (no-op in PAT mode)
#   sync_fork_with_upstream       - Sync fork main with upstream main
#   check_branch_changes          - Detect code changes on current branch

GITHUB_APP_CREDS_DIR="/var/run/claude-code-service-account"

# ── PAT mode ──────────────────────────────────────────────────────────────────

# Load a classic PAT from the credential secret.
# Sets: GITHUB_TOKEN_PAT
# Requires: JIRA_AGENT_PAT_KEY
_load_pat_credentials() {
  echo "Loading GitHub PAT credentials..."
  local pat_file="${GITHUB_APP_CREDS_DIR}/${JIRA_AGENT_PAT_KEY:-gh-pat}"

  if [ ! -f "$pat_file" ]; then
    echo "ERROR: PAT file not found: $pat_file"
    echo "Available files:"
    ls -la "${GITHUB_APP_CREDS_DIR}/" || echo "Directory does not exist"
    exit 1
  fi

  [[ $- == *x* ]] && local _was_tracing=true || local _was_tracing=false
  set +x

  GITHUB_TOKEN_PAT=$(cat "$pat_file")
  if [ -z "$GITHUB_TOKEN_PAT" ]; then
    echo "ERROR: PAT file is empty: $pat_file"
    $_was_tracing && set -x || true
    exit 1
  fi

  # PAT mode uses a single token for everything (push + PR creation)
  git config --global credential.helper "!f() { echo username=x-access-token; echo password=${GITHUB_TOKEN_PAT}; }; f"
  export GITHUB_TOKEN="$GITHUB_TOKEN_PAT"
  echo "PAT configured for git and GitHub CLI"

  $_was_tracing && set -x || true
}

# Ensure a fork of the upstream repo exists in the bot user's account.
# Creates the fork via GitHub API if it doesn't exist, then polls until ready.
# Sets: JIRA_AGENT_FORK_REPO, FORK_ORG
# Requires: JIRA_AGENT_UPSTREAM_REPO, JIRA_AGENT_FORK_ORG, GITHUB_TOKEN
ensure_fork_exists() {
  if [ "${JIRA_AGENT_AUTH_MODE:-app}" != "pat" ]; then
    echo "Skipping ensure_fork_exists (not in PAT mode)"
    return 0
  fi

  local upstream_repo="${JIRA_AGENT_UPSTREAM_REPO}"
  local fork_org="${JIRA_AGENT_FORK_ORG}"
  local repo_name="${upstream_repo#*/}"

  if [ -z "$fork_org" ]; then
    echo "ERROR: JIRA_AGENT_FORK_ORG is required in PAT mode"
    exit 1
  fi

  echo "Checking if fork ${fork_org}/${repo_name} exists..."

  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${fork_org}/${repo_name}")

  if [ "$http_code" = "200" ]; then
    echo "Fork ${fork_org}/${repo_name} already exists"
  else
    echo "Fork not found (HTTP ${http_code}). Creating fork of ${upstream_repo}..."
    local fork_response
    fork_response=$(curl -s -X POST \
      --connect-timeout 10 --max-time 30 \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${upstream_repo}/forks" \
      -d "{\"default_branch_only\":true}")

    local fork_full_name
    fork_full_name=$(echo "$fork_response" | jq -r '.full_name // empty' 2>/dev/null)
    if [ -z "$fork_full_name" ]; then
      echo "ERROR: Failed to create fork. API response:"
      echo "$fork_response" | head -20
      exit 1
    fi
    echo "Fork creation initiated: ${fork_full_name}"

    # Poll until the fork is ready (GitHub forks are async)
    local max_wait=120
    local waited=0
    while [ $waited -lt $max_wait ]; do
      http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${fork_org}/${repo_name}")
      if [ "$http_code" = "200" ]; then
        echo "Fork ${fork_org}/${repo_name} is ready"
        break
      fi
      echo "Waiting for fork to be ready... (${waited}s/${max_wait}s)"
      sleep 10
      waited=$((waited + 10))
    done

    if [ "$http_code" != "200" ]; then
      echo "ERROR: Fork not ready after ${max_wait}s"
      exit 1
    fi
  fi

  export JIRA_AGENT_FORK_REPO="${fork_org}/${repo_name}"
  export FORK_ORG="${fork_org}"
  echo "Fork repo set to: ${JIRA_AGENT_FORK_REPO}"
}

# Resolve the upstream repo for an issue from its Jira component.
# Uses JIRA_AGENT_COMPONENT_REPO_MAP (JSON object) to map component names to repos.
# Falls back to JIRA_AGENT_UPSTREAM_REPO if no map is configured or component not found.
# Sets: JIRA_AGENT_UPSTREAM_REPO (exported), JIRA_AGENT_FORK_REPO (exported), FORK_ORG (exported)
# Requires: JIRA_AUTH, JIRA_BASE_URL, JIRA_AGENT_FORK_ORG (in PAT mode)
resolve_upstream_repo() {
  local issue_key="$1"
  local component_map="${JIRA_AGENT_COMPONENT_REPO_MAP:-}"

  if [ -z "$component_map" ]; then
    echo "No component-repo map configured, using JIRA_AGENT_UPSTREAM_REPO=${JIRA_AGENT_UPSTREAM_REPO}"
    return 0
  fi

  echo "Resolving upstream repo for ${issue_key} from Jira component..."
  local issue_response http_code component resolved_repo
  issue_response=$(curl -s -w "\n%{http_code}" \
    "${JIRA_BASE_URL}/rest/api/3/issue/${issue_key}?fields=components" \
    -H "Authorization: Basic $JIRA_AUTH" \
    -H "Content-Type: application/json")
  http_code=$(echo "$issue_response" | tail -1)

  if [ "$http_code" != "200" ]; then
    echo "Warning: Failed to fetch issue components (HTTP ${http_code}), using default JIRA_AGENT_UPSTREAM_REPO"
    return 0
  fi

  component=$(echo "$issue_response" | sed '$d' | jq -r '.fields.components[0].name // empty')
  if [ -z "$component" ]; then
    echo "Warning: Issue ${issue_key} has no components, using default JIRA_AGENT_UPSTREAM_REPO"
    return 0
  fi

  echo "Issue component: ${component}"
  resolved_repo=$(echo "$component_map" | jq -r --arg c "$component" '.[$c] // empty')

  if [ -z "$resolved_repo" ]; then
    echo "Warning: Component '${component}' not found in JIRA_AGENT_COMPONENT_REPO_MAP, using default JIRA_AGENT_UPSTREAM_REPO"
    return 0
  fi

  export JIRA_AGENT_UPSTREAM_REPO="$resolved_repo"
  echo "Resolved upstream repo: ${JIRA_AGENT_UPSTREAM_REPO}"

  # In PAT mode, also update the fork repo
  if [ "${JIRA_AGENT_AUTH_MODE:-app}" = "pat" ] && [ -n "${JIRA_AGENT_FORK_ORG:-}" ]; then
    export JIRA_AGENT_FORK_REPO="${JIRA_AGENT_FORK_ORG}/${resolved_repo#*/}"
    export FORK_ORG="${JIRA_AGENT_FORK_ORG}"
    echo "Updated fork repo: ${JIRA_AGENT_FORK_REPO}"
  fi
}

# Clone, fork (if needed), and sync a repo for processing.
# Call once per issue when JIRA_AGENT_COMPONENT_REPO_MAP is set (repo changes per issue).
# Requires: JIRA_AGENT_FORK_REPO, JIRA_AGENT_UPSTREAM_REPO
setup_repo() {
  rm -rf /tmp/project-repo

  ensure_fork_exists

  echo "Cloning ${JIRA_AGENT_FORK_REPO}..."
  git clone "https://github.com/${JIRA_AGENT_FORK_REPO}" /tmp/project-repo
  cd /tmp/project-repo

  sync_fork_with_upstream
}

# ── GitHub App mode ───────────────────────────────────────────────────────────

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

# ── Auth mode dispatcher ─────────────────────────────────────────────────────

# Load credentials based on JIRA_AGENT_AUTH_MODE.
# In "pat" mode: loads PAT from secret, configures git + GITHUB_TOKEN.
# In "app" mode: loads GitHub App credentials, generates installation tokens.
load_credentials() {
  if [ "${JIRA_AGENT_AUTH_MODE:-app}" = "pat" ]; then
    _load_pat_credentials
  else
    load_github_app_credentials
    generate_and_configure_tokens
  fi
}

# Refresh the fork GitHub App token and update git credential helper.
# No-op in PAT mode (PATs don't expire mid-run).
refresh_fork_token() {
  if [ "${JIRA_AGENT_AUTH_MODE:-app}" = "pat" ]; then
    return 0
  fi
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
# No-op in PAT mode.
refresh_upstream_token() {
  if [ "${JIRA_AGENT_AUTH_MODE:-app}" = "pat" ]; then
    return 0
  fi
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
# No-op in PAT mode.
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
  # Claude Code may leave a stale lock after timeout/kill between issues
  rm -f .git/index.lock
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
