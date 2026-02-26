#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# ============================================================================
# SECURITY WARNING: This script handles sensitive credentials
# ============================================================================
# - GitHub tokens (GITHUB_TOKEN)
# - Jira tokens (JIRA_TOKEN)
#
# NEVER enable 'set -x' or 'set -o xtrace' as it will expose credentials in logs
# ============================================================================

# Security: Explicitly disable command tracing to prevent credential exposure
set +o xtrace

# Logging functions with timestamps
log() { echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] ${*}"; }
info() { log "[info] ${*}"; }
error() { log "[error] ${*}"; exit 1; }

# Precheck: Ensure we're in a git repository
if [[ ! -d ".git" ]]; then
  error "precheck: not in a git repository"
fi

# Precheck: Ensure all required tools are present
info "precheck: ensure required tools are present"
required_tools=(git make curl python3)
for cmd in "${required_tools[@]}"; do
  command -v "${cmd}" &> /dev/null || error "required tool '${cmd}' is not installed or not in PATH."
done
info "precheck: all required tools are present"

# Precheck: Ensure this job is running from the expected release version config
# This prevents duplicate runs when periodic configs are copied to new release versions
if [[ -z "${EXPECTED_RELEASE_VERSION:-}" ]]; then
  error "precheck: EXPECTED_RELEASE_VERSION must be set. This job should only run from one periodic config."
fi

if [[ -n "${JOB_NAME:-}" ]]; then
  if [[ ! "${JOB_NAME}" =~ release-${EXPECTED_RELEASE_VERSION} ]]; then
    error "precheck: JOB_NAME '${JOB_NAME}' does not match EXPECTED_RELEASE_VERSION '${EXPECTED_RELEASE_VERSION}'.
This job should only run from the release-${EXPECTED_RELEASE_VERSION} periodic config.
If you copied this config to a new release version, please:
1. Update EXPECTED_RELEASE_VERSION to match the new version
2. Remove this job from other periodic configs (only one should exist)
3. Update CHERRY_PICK_BRANCHES if needed"
  fi
fi
info "precheck: release version check passed (${EXPECTED_RELEASE_VERSION})"

# Configuration: Load GitHub token from file
info "cfg: loading GitHub token"
if [[ ! -f "${GITHUB_TOKEN_PATH}" ]]; then
  error "github: token file not found at ${GITHUB_TOKEN_PATH}"
fi

# Security: Load token without printing it
GITHUB_TOKEN=$(cat "${GITHUB_TOKEN_PATH}")
readonly GITHUB_TOKEN
info "cfg: GitHub token loaded successfully"

# Configuration: Load Jira token from file (optional - bug creation will be skipped if not available)
JIRA_TOKEN=""
if [[ -n "${JIRA_TOKEN_PATH:-}" ]] && [[ -f "${JIRA_TOKEN_PATH}" ]]; then
  info "cfg: loading Jira token"
  JIRA_TOKEN=$(cat "${JIRA_TOKEN_PATH}")
  info "cfg: Jira token loaded successfully"
else
  info "cfg: Jira token not configured, bug creation will be skipped"
fi

# Jira API base URL
JIRA_API="https://issues.redhat.com/rest/api/2"

# GitHub API base URL
GITHUB_API="https://api.github.com"

# Fork configuration: The bot user's fork of the repository
FORK_OWNER="${GITHUB_PR_USER}"
FORK_REMOTE="fork"

# Git: Configure credential helper for secure authentication
# This approach prevents token leakage in git remote output (e.g., git remote -v)
info "git: configuring credential helper for authentication"
git config credential.helper "!f() { echo username=x-access-token; echo password=${GITHUB_TOKEN}; }; f"

# Git: Add fork remote for pushing branches
info "git: adding fork remote"
git remote add "${FORK_REMOTE}" "https://github.com/${FORK_OWNER}/${GITHUB_REPO_NAME}.git" 2>/dev/null || \
  git remote set-url "${FORK_REMOTE}" "https://github.com/${FORK_OWNER}/${GITHUB_REPO_NAME}.git"

# GitHub API helper function
# Security: Uses -s (silent) to prevent token exposure in error messages
github_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  if [[ -n "${data}" ]]; then
    curl -s -X "${method}" \
      -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github.v3+json" \
      -H "Content-Type: application/json" \
      -d "${data}" \
      "${GITHUB_API}${endpoint}"
  else
    curl -s -X "${method}" \
      -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github.v3+json" \
      "${GITHUB_API}${endpoint}"
  fi
}

# Jira API helper function
# Security: Uses -s (silent) to prevent token exposure in error messages
jira_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  if [[ -n "${data}" ]]; then
    curl -s -X "${method}" \
      -H "Authorization: Bearer ${JIRA_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "${data}" \
      "${JIRA_API}${endpoint}"
  else
    curl -s -X "${method}" \
      -H "Authorization: Bearer ${JIRA_TOKEN}" \
      -H "Content-Type: application/json" \
      "${JIRA_API}${endpoint}"
  fi
}

# Derive Jira target version from JOB_NAME
# Example: periodic-ci-openshift-machine-config-operator-release-4.22-periodics-update-amis -> 4.22.0
# Returns empty string if version cannot be derived (reviewer will need to set it manually)
get_jira_target_version() {
  if [[ -n "${JOB_NAME:-}" ]] && [[ "${JOB_NAME}" =~ release-([0-9]+\.[0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}.0"
  else
    echo ""
  fi
}

# Create a Jira bug and return the issue key
# Arguments: summary, description
# Returns: Issue key (e.g., OCPBUGS-12345) or empty string on failure
create_jira_bug() {
  local summary="$1"
  local description="$2"
  local target_version
  target_version=$(get_jira_target_version)

  if [[ -n "${target_version}" ]]; then
    info "jira: creating bug with target version ${target_version}" >&2
  else
    info "jira: creating bug without target version (reviewer will need to set it)" >&2
  fi

  local bug_json
  bug_json=$(python3 -c "
import json
fields = {
    'project': {'key': 'OCPBUGS'},
    'summary': '''${summary}''',
    'description': '''${description}''',
    'issuetype': {'name': 'Bug'},
    'components': [{'name': 'Machine Config Operator'}],
    'priority': {'name': 'Normal'}
}
target_version = '${target_version}'
if target_version:
    fields['versions'] = [{'name': target_version}]
    fields['customfield_12319940'] = [{'name': target_version}]  # Target Version
print(json.dumps({'fields': fields}))
")

  local response
  response=$(jira_api POST "/issue" "${bug_json}")

  local issue_key
  issue_key=$(echo "${response}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('key', ''))
except:
    print('')
" 2>/dev/null || echo "")

  if [[ -n "${issue_key}" ]]; then
    info "jira: created bug ${issue_key}" >&2
    echo "${issue_key}"
  else
    local error_msg
    error_msg=$(echo "${response}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    errors = data.get('errors', {})
    error_messages = data.get('errorMessages', [])
    if errors:
        print(json.dumps(errors))
    elif error_messages:
        print(', '.join(error_messages))
    else:
        print('Unknown error')
except:
    print('Failed to parse response')
" 2>/dev/null || echo "Unknown error")
    info "jira: failed to create bug - ${error_msg}" >&2
    echo ""
  fi
}

# Git: Configure git user and email for commits
info "git: configure git user and email"
git config user.name "${GITHUB_PR_USER}"
git config user.email "${GITHUB_PR_EMAIL}"

# Run make update-amis
info "mco: running make update-amis"
make update-amis

# Check if there are any changes
if [[ $(git status --porcelain) == "" ]]; then
  info "mco: no AMI updates found"
  exit 0
fi  

info "mco: AMI updates found, preparing to create PR"

# GitHub: Check if there's already an open PR for AMI updates
# Match PRs that start with [Automated] and contain the title description
info "github: checking for existing PR"
EXISTING_PR_INFO=$(github_api GET "/repos/${GITHUB_REPO_ORG}/${GITHUB_REPO_NAME}/pulls?state=open&per_page=100" | \
  python3 -c "
import sys, json
prs = json.load(sys.stdin)
title_desc = '${GITHUB_PR_TITLE}'
user = '${GITHUB_PR_USER}'
for pr in prs:
    pr_title = pr.get('title', '')
    if pr_title.startswith('[Automated]') and title_desc in pr_title and pr.get('user', {}).get('login') == user:
        print(f\"{pr['number']}|{pr['head']['ref']}|{pr['html_url']}\")
        break
" 2>/dev/null || echo "")

if [[ -n "${EXISTING_PR_INFO}" ]]; then
  # Extract PR number, branch name, and URL from existing PR
  EXISTING_PR_NUMBER=$(echo "${EXISTING_PR_INFO}" | cut -d'|' -f1)
  EXISTING_BRANCH=$(echo "${EXISTING_PR_INFO}" | cut -d'|' -f2)
  EXISTING_PR_URL=$(echo "${EXISTING_PR_INFO}" | cut -d'|' -f3)
  info "github: existing PR #${EXISTING_PR_NUMBER} found on branch ${EXISTING_BRANCH}"

  # Fetch the existing branch from fork to compare
  git fetch "${FORK_REMOTE}" "${EXISTING_BRANCH}"

  # Stage our local changes to compare
  git add -A

  # Compare local changes against the existing PR branch
  # If the diff between our staged changes and the PR branch is empty, no update needed
  if git diff --staged --quiet "${FORK_REMOTE}/${EXISTING_BRANCH}" -- ; then
    info "github: existing PR already has the same changes, skipping update"
    info "github: existing PR at ${EXISTING_PR_URL}"
    exit 0
  fi

  info "github: changes differ from existing PR, updating it"

  # Stash changes, checkout the existing branch, apply changes
  git stash
  git checkout -B "${EXISTING_BRANCH}" "${FORK_REMOTE}/${EXISTING_BRANCH}"
  git stash pop

  # Commit and force-push to update the existing PR
  info "git: committing AMI updates"
  git add -A
  git commit -m "chore: update AMIs

This is an automated commit to update AMI IDs.
"

  info "git: pushing updates to existing branch on fork"
  git push --force-with-lease "${FORK_REMOTE}" "${EXISTING_BRANCH}"

  # Add a comment to the PR indicating it was updated
  COMMENT_BODY="Updated with latest AMI changes at $(date +%Y-%m-%dT%H:%M:%S%z)"
  COMMENT_JSON=$(python3 -c "import json; print(json.dumps({'body': '${COMMENT_BODY}'}))")
  github_api POST "/repos/${GITHUB_REPO_ORG}/${GITHUB_REPO_NAME}/issues/${EXISTING_PR_NUMBER}/comments" \
    "${COMMENT_JSON}" > /dev/null

  info "github: PR updated at ${EXISTING_PR_URL}"
else
  # No existing PR, create a new one
  BRANCH_NAME="automated-ami-update-$(date +%Y%m%d-%H%M%S)"
  info "git: creating branch ${BRANCH_NAME}"
  git checkout -b "${BRANCH_NAME}"

  # Git: Commit the changes
  info "git: committing AMI updates"
  git add -A
  git commit -m "chore: update AMIs

This is an automated commit to update AMI IDs.
"

  # Git: Push the branch to fork
  info "git: pushing branch to fork"
  git push "${FORK_REMOTE}" "${BRANCH_NAME}"

  # Jira: Create a bug to track this AMI update (only for new PRs)
  JIRA_BUG_KEY=""
  if [[ -n "${JIRA_TOKEN}" ]]; then
    info "jira: creating bug for AMI update"
    BUG_SUMMARY="[Automated] ${GITHUB_PR_TITLE}"
    BUG_DESCRIPTION="This is an automated bug to track AMI ID updates for the Machine Config Operator.

A pull request will be created with the updated AMI IDs.

This bug was automatically created by the periodic-ci-openshift-machine-config-operator-update-amis job."
    JIRA_BUG_KEY=$(create_jira_bug "${BUG_SUMMARY}" "${BUG_DESCRIPTION}")
  fi

  # GitHub: Create Pull Request
  info "github: creating pull request"

  # Build PR title (include Jira bug key if available)
  # Format: [Automated]OCPBUGS-12345: Update AMI Whitelist
  if [[ -n "${JIRA_BUG_KEY}" ]]; then
    FINAL_PR_TITLE="[Automated] ${JIRA_BUG_KEY}: ${GITHUB_PR_TITLE}"
  else
    FINAL_PR_TITLE="[Automated] ${GITHUB_PR_TITLE}"
  fi

  # Build PR body
  DIFF_STAT=$(git diff HEAD~1 --stat)
  PR_BODY="## Summary
This automated PR updates AMI IDs to the latest versions.

## Changes
\`\`\`
${DIFF_STAT}
\`\`\`

---
**Generated by:** periodic-ci-openshift-machine-config-operator-update-amis
**Generated at:** $(date +%Y-%m-%dT%H:%M:%S%z)"

  # Build JSON payload using Python to properly escape
  # Note: head must be in 'user:branch' format when PR is from a fork
  PR_JSON=$(python3 -c "
import json
print(json.dumps({
    'title': '''${FINAL_PR_TITLE}''',
    'head': '${FORK_OWNER}:${BRANCH_NAME}',
    'base': '${GITHUB_REPO_BRANCH}',
    'body': '''${PR_BODY}'''
}))
")

  PR_RESPONSE=$(github_api POST "/repos/${GITHUB_REPO_ORG}/${GITHUB_REPO_NAME}/pulls" "${PR_JSON}")

  PR_URL=$(echo "${PR_RESPONSE}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('html_url', ''))
" 2>/dev/null || echo "")

  if [[ -z "${PR_URL}" ]]; then
    ERROR_MSG=$(echo "${PR_RESPONSE}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('message', data.get('errors', 'Unknown error')))
" 2>/dev/null || echo "Unknown error")
    error "github: failed to create PR - ${ERROR_MSG}"
  fi

  info "github: PR created at ${PR_URL}"
  if [[ -n "${JIRA_BUG_KEY}" ]]; then
    info "jira: bug ${JIRA_BUG_KEY} linked via PR title"
  fi

  # Add cherry-pick comment if branches are configured
  if [[ -n "${CHERRY_PICK_BRANCHES:-}" ]]; then
    PR_NUMBER=$(echo "${PR_RESPONSE}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('number', ''))
" 2>/dev/null || echo "")

    if [[ -n "${PR_NUMBER}" ]]; then
      # Construct cherry-pick comment from branch list (space-separated)
      CHERRY_PICK_COMMENT="/cherry-pick ${CHERRY_PICK_BRANCHES}"
      info "github: adding cherry-pick comment to PR #${PR_NUMBER}"
      COMMENT_JSON=$(python3 -c "import json; print(json.dumps({'body': '''${CHERRY_PICK_COMMENT}'''}))")
      github_api POST "/repos/${GITHUB_REPO_ORG}/${GITHUB_REPO_NAME}/issues/${PR_NUMBER}/comments" \
        "${COMMENT_JSON}" > /dev/null
    fi
  fi
fi

exit 0
