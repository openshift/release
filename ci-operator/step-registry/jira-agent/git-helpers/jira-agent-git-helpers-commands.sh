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
#   sync_fork_with_upstream       - Sync fork with upstream default branch
#   check_branch_changes          - Detect code changes on current branch

GITHUB_APP_CREDS_DIR="/var/run/claude-code-service-account"
DEFAULT_BRANCH="${JIRA_AGENT_DEFAULT_BRANCH:-main}"

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

# Resolve the per-issue routing for an issue from its Jira component/project.
# In the single all-teams job the repo (and its review profile, Slack emoji and
# Jira assignee) differs per issue, so this is called once per issue.
#
# Repo resolution:
#   1. JIRA_AGENT_COMPONENT_REPO_MAP[component]  (primary — all of the issue's
#      Jira components are checked; routes when they agree on one repo, skips if
#      they map to different repos)
#   2. JIRA_AGENT_PROJECT_REPO_MAP[project]      (fallback — issue key prefix,
#      e.g. WINC-9 -> WINC, for teams routed by project without a component)
# Returns 0 without changes when no component map is configured (static mode).
# Returns non-zero when a map is configured but the issue cannot be routed (HTTP
# error, ambiguous components, or no matching component/project); the caller must
# skip that issue rather than process it against another issue's repo.
#
# Per-issue fields (only when the corresponding map is set; keyed by component,
# defaults applied when routed by project or the component has no entry):
#   REVIEW_PROFILE       <- JIRA_AGENT_COMPONENT_PROFILE_MAP  (default "")
#   SLACK_EMOJI          <- JIRA_AGENT_COMPONENT_EMOJI_MAP    (default ":robot:")
#   JIRA_AGENT_ASSIGNEE  <- JIRA_AGENT_COMPONENT_ASSIGNEE_MAP (default "")
#   DEFAULT_BRANCH       <- JIRA_AGENT_REPO_BRANCH_MAP        (default "main")
#
# Sets: JIRA_AGENT_UPSTREAM_REPO, JIRA_AGENT_FORK_REPO, FORK_ORG (all exported)
# Requires: JIRA_AUTH, JIRA_BASE_URL, JIRA_AGENT_FORK_ORG (in PAT mode)
resolve_upstream_repo() {
  local issue_key="$1"
  local component_map="${JIRA_AGENT_COMPONENT_REPO_MAP:-}"
  local project_map="${JIRA_AGENT_PROJECT_REPO_MAP:-}"
  local branch_map="${JIRA_AGENT_REPO_BRANCH_MAP:-}"
  local profile_map="${JIRA_AGENT_COMPONENT_PROFILE_MAP:-}"
  local emoji_map="${JIRA_AGENT_COMPONENT_EMOJI_MAP:-}"
  local assignee_map="${JIRA_AGENT_COMPONENT_ASSIGNEE_MAP:-}"

  if [ -z "$component_map" ]; then
    echo "No component-repo map configured, using JIRA_AGENT_UPSTREAM_REPO=${JIRA_AGENT_UPSTREAM_REPO}"
    return 0
  fi

  echo "Resolving upstream repo for ${issue_key} from Jira component..."
  local issue_response http_code component resolved_repo project_key c mapped ambiguous
  issue_response=$(curl -s -w "\n%{http_code}" \
    "${JIRA_BASE_URL}/rest/api/3/issue/${issue_key}?fields=components" \
    -H "Authorization: Basic $JIRA_AUTH" \
    -H "Content-Type: application/json")
  http_code=$(echo "$issue_response" | tail -1)

  if [ "$http_code" != "200" ]; then
    echo "Warning: Failed to fetch issue components for ${issue_key} (HTTP ${http_code}); skipping issue"
    return 1
  fi

  # 1) Component-based routing (primary). Examine ALL of the issue's components,
  # not just the first: a Jira issue can carry multiple components and the union
  # JQL matches on any one of them. Route when the mapped components agree on a
  # single repo; skip if they map to different repos (ambiguous) rather than
  # guess (which could bypass a team's label gate).
  resolved_repo=""
  component=""
  ambiguous=false
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    mapped=$(echo "$component_map" | jq -r --arg c "$c" '.[$c] // empty')
    [ -z "$mapped" ] && continue
    if [ -z "$resolved_repo" ]; then
      resolved_repo="$mapped"
      component="$c"
    elif [ "$mapped" != "$resolved_repo" ]; then
      ambiguous=true
    fi
  done < <(echo "$issue_response" | sed '$d' | jq -r '.fields.components[]?.name // empty')

  if [ "$ambiguous" = true ]; then
    echo "Warning: ${issue_key} components map to multiple repos; skipping (ambiguous routing)"
    return 1
  fi
  if [ -n "$component" ]; then
    echo "Routing component: ${component} -> ${resolved_repo}"
  else
    echo "Issue ${issue_key} has no mapped component; will try project-based routing"
  fi

  # 2) Project-based routing (fallback) keyed by the issue key prefix, for issues
  # that don't carry a mapped component (e.g. WINC-9 -> WINC).
  project_key="${issue_key%%-*}"
  if [ -z "$resolved_repo" ] && [ -n "$project_map" ]; then
    resolved_repo=$(echo "$project_map" | jq -r --arg p "$project_key" '.[$p] // empty')
    [ -n "$resolved_repo" ] && echo "Resolved via project '${project_key}': ${resolved_repo}"
  fi

  if [ -z "$resolved_repo" ]; then
    echo "Warning: No repo mapping for ${issue_key} (components or project '${project_key}'); skipping"
    return 1
  fi

  export JIRA_AGENT_UPSTREAM_REPO="$resolved_repo"
  echo "Resolved upstream repo: ${JIRA_AGENT_UPSTREAM_REPO}"

  # Check out the repo's default branch (some repos use master, not main).
  # Re-exported every issue so it never bleeds across repos in the loop.
  if [ -n "$branch_map" ]; then
    DEFAULT_BRANCH=$(echo "$branch_map" | jq -r --arg r "$resolved_repo" '.[$r] // "main"')
    export DEFAULT_BRANCH
    echo "Default branch: ${DEFAULT_BRANCH}"
  fi

  # Per-issue review profile / Slack emoji / Jira assignee, keyed by component.
  # Re-exported every issue (even to the default) so values never bleed across
  # issues in the single all-teams loop.
  if [ -n "$profile_map" ]; then
    REVIEW_PROFILE=$(echo "$profile_map" | jq -r --arg c "${component:-}" '.[$c] // empty')
    export REVIEW_PROFILE
  fi
  if [ -n "$emoji_map" ]; then
    SLACK_EMOJI=$(echo "$emoji_map" | jq -r --arg c "${component:-}" '.[$c] // ":robot:"')
    export SLACK_EMOJI
  fi
  if [ -n "$assignee_map" ]; then
    JIRA_AGENT_ASSIGNEE=$(echo "$assignee_map" | jq -r --arg c "${component:-}" '.[$c] // empty')
    export JIRA_AGENT_ASSIGNEE
  fi

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

# Sync fork default branch with upstream.
# Must be called from inside the repo working directory.
# Requires: JIRA_AGENT_UPSTREAM_REPO, DEFAULT_BRANCH
sync_fork_with_upstream() {
  echo "Syncing fork with upstream ${JIRA_AGENT_UPSTREAM_REPO}..."
  git config user.name "OpenShift CI Bot"
  git config user.email "ci-bot@redhat.com"
  git remote add upstream "https://github.com/${JIRA_AGENT_UPSTREAM_REPO}.git"
  git fetch upstream "$DEFAULT_BRANCH"
  git checkout "$DEFAULT_BRANCH"
  git rebase "upstream/$DEFAULT_BRANCH"
  echo "Fork synced with upstream successfully"
}

# Check if code changes exist on the current branch vs default branch.
# Sets: HAS_CODE_CHANGES (true/false), BRANCH_NAME, PR_URL (empty)
check_branch_changes() {
  BRANCH_NAME=$(git branch --show-current)
  HAS_CODE_CHANGES=false
  PR_URL=""

  if [ "$BRANCH_NAME" != "$DEFAULT_BRANCH" ] && [ -n "$BRANCH_NAME" ]; then
    local diff_files
    diff_files=$(git diff "$DEFAULT_BRANCH"...HEAD --name-only 2>/dev/null || echo "")
    if [ -n "$diff_files" ]; then
      HAS_CODE_CHANGES=true
      echo "Code changes detected on branch $BRANCH_NAME"
    fi
  fi
}

# Reset working tree to upstream default branch for a clean starting state between issues.
reset_to_main() {
  # Claude Code may leave a stale lock after timeout/kill between issues
  rm -f .git/index.lock
  git checkout "$DEFAULT_BRANCH" 2>/dev/null || true
  git reset --hard "upstream/$DEFAULT_BRANCH" 2>/dev/null || true
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
