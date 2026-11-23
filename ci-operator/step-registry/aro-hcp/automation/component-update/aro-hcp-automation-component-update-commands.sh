#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# ============================================================================
# SECURITY WARNING: This script handles sensitive credentials
# ============================================================================
# - GitHub App credentials (App ID + private key)
# - Azure credentials (AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID)
# - Slack webhook URLs
#
# NEVER enable 'set -x' or 'set -o xtrace' as it will expose credentials in logs
# Use VERBOSITY environment variable (0-2) for controlled verbosity instead
# ============================================================================

# Security: Explicitly disable command tracing to prevent credential exposure
set +o xtrace

# Security: Trap to ensure xtrace is never accidentally enabled
trap 'set +o xtrace' DEBUG

# Environment variable defaults (overridable via ref.yaml)
VERBOSITY=${VERBOSITY:-1}

# Internal variables (not configurable via ref.yaml)
readonly COMPONENT_UPDATER_OUTPUT="/tmp/component-updater-output.md"
# The full make log is kept for triage; the pull-request body uses only the
# tool's markdown result (the table onward), skipping build/download noise.
readonly COMPONENT_UPDATER_RESULT="/tmp/component-updater-result.md"

# Logging functions with timestamps and severity levels
log() { echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] ${*}"; }
info()  { if [[ ${VERBOSITY-0} -ge 1 ]]; then log "[info] ${*}"; fi; }
debug() { if [[ ${VERBOSITY-0} -ge 2 ]]; then log "[debug] ${*}"; fi; }
error() { log "[error] ${*}"; exit "${ERR_EXIT_CODE:-1}"; }


# Cleanup function to handle failures gracefully
# Track whether a Slack notification has already been attempted for this run,
# so the EXIT-trap cleanup below does not send a second, generic failure
# message after an explicit one (e.g. from a prcreator or PR-poll failure
# path), even when that explicit attempt itself failed.
NOTIFIED=0

# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() {
  local exit_code=${?}
  if [[ ${exit_code} -ne 0 && ${NOTIFIED} -eq 0 ]]; then
    notify "❌ Component updater job failed with exit code ${exit_code}. Please check prow at ${PROW_JOB_URL:-https://prow.ci.openshift.org}" || true
  fi
  exit "${exit_code}"
}
trap cleanup EXIT

# Notify function with error handling for Slack notifications
# notify() never exits on its own and never calls error(): a failing webhook
# must not abort the error path that invoked it, or the EXIT trap would
# recurse into a second notification attempt and mask the original exit code.
# NOTIFIED is set as soon as an attempt is made (success or failure) so
# cleanup() never retries a failed notification.
notify() {
  NOTIFIED=1

  if [[ ! -f "${SLACK_WEBHOOK_PATH}" ]]; then
    log "[error] slack: webhook file not found at ${SLACK_WEBHOOK_PATH}"
    return 1
  fi

  local webhook_url
  if ! webhook_url=$(cat "${SLACK_WEBHOOK_PATH}"); then
    log "[error] slack: failed to read Slack webhook file"
    return 1
  fi

  # Build the JSON body with jq so quotes or backslashes in the message cannot
  # produce invalid JSON (which Slack would reject with a 400).
  local payload
  if ! payload=$(jq -cn --arg text "${*}" '{text: $text}'); then
    log "[error] slack: failed to encode Slack notification"
    return 1
  fi

  # Security: Use silent curl to prevent webhook URL exposure in logs
  # Timeouts bound a stalled webhook so cleanup cannot hang until the job timeout.
  if ! curl -f -s --connect-timeout 10 --max-time 30 -X POST -H 'Content-type: application/json' \
    --data "${payload}" "${webhook_url}" 2>/dev/null; then
    log "[error] slack: failed to send Slack notification"
    return 1
  fi

  debug "slack: notification sent successfully"
}

# Helper function to run commands with conditional verbosity: output is
# hidden while the command succeeds, printed when it fails, so a scheduled
# run's logs show why it failed without re-running at VERBOSITY=2.
# Security Note: In VERBOSITY mode (>=2), command output is visible. Ensure no sensitive
# data is passed through commands executed via this function.
run() {
  if [[ ${VERBOSITY-0} -ge 2 ]]; then
    "$@"
    return
  fi
  local log_file
  if ! log_file=$(mktemp); then
    error "run: failed to create temporary log file"
  fi
  if "$@" > "${log_file}" 2>&1; then
    rm -f "${log_file}"
    return 0
  else
    local rc=$?
    cat "${log_file}"
    rm -f "${log_file}"
    return "${rc}"
  fi
}

# Precheck: Ensure we're in a git repository
if [[ ! -d ".git" ]]; then
  error "precheck: not in a git repository"
fi

# Precheck: Ensure all required tools are present
debug "precheck: ensure required tools are present"
required_tools=(git make jq curl)
for cmd in "${required_tools[@]}"; do
  command -v "${cmd}" &> /dev/null || error "required tool '${cmd}' is not installed or not in PATH."
done
debug "precheck: all required tools are present"

# Configuration: Validate GitHub App credentials
debug "cfg: validating GitHub App credentials"
if [[ ! -f "${GITHUB_APP_ID_PATH}" ]]; then
  error "github: App ID file not found at ${GITHUB_APP_ID_PATH}"
fi
if [[ ! -f "${GITHUB_APP_KEY_PATH}" ]]; then
  error "github: App private key file not found at ${GITHUB_APP_KEY_PATH}"
fi
debug "cfg: GitHub App credentials validated successfully"

# Git: Configure git user and email for local commits
debug "git: configure git user and email"
git config user.name "${GITHUB_PR_USER}"
git config user.email "${GITHUB_PR_EMAIL}"

# Azure: Configure Azure Authentication with credential validation
debug "azure: configure Azure Authentication"

# Validate credential files exist before reading
for cred_file in "client-id" "client-secret" "tenant"; do
  if [[ ! -f "${AZURE_CREDENTIALS_DIR}/${cred_file}" ]]; then
    error "azure: credential file not found: ${AZURE_CREDENTIALS_DIR}/${cred_file}"
  fi
done

# Security: Load credentials without printing them
AZURE_CLIENT_ID="$(cat "${AZURE_CREDENTIALS_DIR}/client-id")"
readonly AZURE_CLIENT_ID
export AZURE_CLIENT_ID

AZURE_CLIENT_SECRET="$(cat "${AZURE_CREDENTIALS_DIR}/client-secret")"
readonly AZURE_CLIENT_SECRET
export AZURE_CLIENT_SECRET

AZURE_TENANT_ID="$(cat "${AZURE_CREDENTIALS_DIR}/tenant")"
readonly AZURE_TENANT_ID
export AZURE_TENANT_ID
export AZURE_TOKEN_CREDENTIALS=prod

# AZURE_SUBSCRIPTION_ID is provided via ref.yaml env; the tool also falls back
# to sole-enabled-subscription discovery if it is ever unset.
export AZURE_SUBSCRIPTION_ID

debug "azure: authentication configured successfully (credentials redacted)"

# Component Updater: Build and run the component-updater tool.
# - check: read-only discovery; the tool writes nothing, and the script stops
#   here (no commit, no pull request) so the job can be validated safely.
# - update: the tool edits config/config.yaml and runs `make -C config
#   materialize` (including Helm fixtures) itself. If the tool fails after the
#   source edit but before/during materialize, the script exits nonzero below
#   without committing, so no pull request can result.
readonly COMPONENT_UPDATER_MODE=${MODE:-check}
if [[ "${COMPONENT_UPDATER_MODE}" != "check" && "${COMPONENT_UPDATER_MODE}" != "update" ]]; then
  error "component: invalid MODE '${COMPONENT_UPDATER_MODE}'; expected 'check' or 'update'"
fi

# Publication is per component: the PR title (and therefore prcreator's branch)
# is scoped to one component, so a multi-component or empty selection would
# fold several components' changes into a single unscoped PR. Enforce exactly
# one component in update mode, before any changes are made; check mode may
# discover for any selection (the tool reports per-component results).
if [[ "${COMPONENT_UPDATER_MODE}" == "update" ]]; then
  if [[ -z "${COMPONENT}" ]]; then
    error "component: update mode requires COMPONENT to name exactly one component; an empty value selects all components, which cannot be published as one PR"
  fi
  if [[ "${COMPONENT}" == *,* ]]; then
    error "component: update mode requires COMPONENT to name exactly one component; per-component publication of comma-separated selections is not implemented"
  fi
fi

info "component: discovering version updates for ${COMPONENT} (mode: ${COMPONENT_UPDATER_MODE})"
if ! make "component-updater-${COMPONENT_UPDATER_MODE}" COMPONENT="${COMPONENT}" > "${COMPONENT_UPDATER_OUTPUT}" 2>&1; then
  cat "${COMPONENT_UPDATER_OUTPUT}"
  error "component: component-updater failed; see output above"
fi

# Extract the tool's markdown result (first table row onward) for the PR body.
sed -n '/^|/,$p' "${COMPONENT_UPDATER_OUTPUT}" > "${COMPONENT_UPDATER_RESULT}" || true
if [[ ! -s "${COMPONENT_UPDATER_RESULT}" ]]; then
  cp "${COMPONENT_UPDATER_OUTPUT}" "${COMPONENT_UPDATER_RESULT}"
fi

# Check mode: report the discovery result and stop — no commit, no pull request.
if [[ "${COMPONENT_UPDATER_MODE}" == "check" ]]; then
  info "component: check mode — discovery result for ${COMPONENT}:"
  cat "${COMPONENT_UPDATER_OUTPUT}"
  exit 0
fi

# Check if there are any changes from component updates
if [[ $(git status --porcelain) == "" ]]; then
  info "component: no version updates available for ${COMPONENT}"
  exit 0
else
  info "component: version updates found for ${COMPONENT}"
  if [[ ${VERBOSITY-0} -ge 1 ]]; then cat "${COMPONENT_UPDATER_OUTPUT}"; echo; fi
fi

# Git: Leave the component-updater's changes uncommitted for prcreator.
# prcreator (pr-source-mode=branch) is responsible for staging and committing
# the working tree: it runs `git add -A` (so new, as-yet-untracked rendered
# config and fixture files are included) and commits with -git-message. It
# also treats a clean tree as "nothing to do" and exits successfully without
# opening a PR, so committing here would silently skip PR creation entirely.
# Security Note: Only show diff in high debug mode; ensure no credential files are in the diff
if [[ ${VERBOSITY-0} -ge 2 ]]; then
  debug "git: changes to be merged into main"
  git --no-pager diff main
  debug "git: untracked files"
  git status --porcelain
fi

# GitHub: Create Pull Request using prcreator
info "git: creating the pull request"

# prcreator derives the head branch from the PR title and upserts the PR by
# (title, branch), so a component-scoped title gives each component its own
# PR while repeated runs update it instead of duplicating. The separator must
# stay ref-safe (git-check-ref-format rejects brackets and similar
# punctuation), or prcreator's `git checkout -B` fails.
if [[ -n "${COMPONENT}" ]]; then
  readonly PR_TITLE="${GITHUB_PR_TITLE} - ${COMPONENT}"
else
  readonly PR_TITLE="${GITHUB_PR_TITLE}"
fi

# The preceding aro-hcp-github-app-auth step writes a short-lived installation
# token here; unauthenticated polls are per-IP rate-limited on shared build
# pods. Checked before prcreator so a missing token (the auth step's rehearsal
# guard can skip minting) fails the job before any real PR is created.
# Security: the token is only ever passed to curl; it is never logged.
readonly GITHUB_TOKEN_PATH="${SHARED_DIR}/github-token"
if [[ ! -s "${GITHUB_TOKEN_PATH}" ]]; then
  error "github: no installation token at ${GITHUB_TOKEN_PATH}; the aro-hcp-github-app-auth step must run first"
fi
PR_POLL_TOKEN=$(cat "${GITHUB_TOKEN_PATH}")

# Temporarily disable errexit to capture exit code
set +o errexit
run /usr/bin/prcreator \
  -github-app-id="$(cat "${GITHUB_APP_ID_PATH}")" \
  -github-app-private-key-path="${GITHUB_APP_KEY_PATH}" \
  -pr-source-mode=branch \
  -organization="${GITHUB_REPO_ORG}" \
  -repo="${GITHUB_REPO_NAME}" \
  -branch="${GITHUB_REPO_BRANCH}" \
  -git-message="chore: execute component-updater for ${COMPONENT}" \
  -pr-title="${PR_TITLE}" \
  -pr-message="This automated PR updates ARO-HCP component versions (${COMPONENT}) to the latest revision available and AKS-compatible in every mesh region.

$(cat "${COMPONENT_UPDATER_RESULT}")

---
**Schedule:** Monday through Thursday at 10:00 AM AEST (00:00 UTC)
**Generated by:** [periodic-ci-Azure-ARO-HCP-main-component-updater-component-updater-tooling](${PROW_JOB_URL})
**Generated at:** $(date +%Y-%m-%dT%H:%M:%S%z)
"
prcreator_exit_code=${?}
set -o errexit

# Verify prcreator succeeded
# notify() is best-effort: under errexit a failing webhook would abort before
# the error below and lose the actual prcreator cause, so failures are ignored.
if [[ ${prcreator_exit_code} -ne 0 ]]; then
  notify "❌ Component updater job failed to create PR. Please check prow at ${PROW_JOB_URL}" || true
  error "github: prcreator command failed with exit code ${prcreator_exit_code}"
fi

# GitHub: Poll for this run's PR with exponential backoff
info "github: checking for existing PR"

readonly PR_CHECK_MAX_ATTEMPTS=${PR_CHECK_MAX_ATTEMPTS:-8}
SLEEP_TIME=10  # Start with 10 seconds

# prcreator's branchNameFromTitle, mirrored here (lowercase; spaces and
# colons become "-"; ASCII titles; keep in sync with ci-tools). Matching the
# head branch alone is unique to this run's PR and, unlike the title, survives
# maintainers renaming the PR.
PR_BRANCH="$(printf '%s' "${PR_TITLE}" | tr '[:upper:]' '[:lower:]' | tr ' :' '--')"

PR_URL=""
PR_POLL_HTTP_CODE=""  # HTTP status of the last poll attempt, for error reporting
PR_POLL_SUCCEEDED=0   # whether any attempt returned HTTP 200
for ((i=1; i<=PR_CHECK_MAX_ATTEMPTS; i++)); do
  debug "github: attempting to find PR (attempt ${i} of ${PR_CHECK_MAX_ATTEMPTS})"

  # Treat a failed poll (transport error or non-200 response) as an
  # unsuccessful attempt instead of letting errexit fail the job; the retry
  # loop masks it. The response's status line is appended by curl's -w so an
  # API error (auth, rate limit, 5xx) can be distinguished from "no PR" in the
  # final error message below. Query parameters go through --data-urlencode
  # so characters like '+', '%' or '#' in the branch name cannot corrupt the
  # head= filter.
  PR_POLL_RESPONSE=$( { curl -s --connect-timeout 10 --max-time 30 \
    -w '\n%{http_code}' -G \
    -H "Authorization: Bearer ${PR_POLL_TOKEN}" \
    --data-urlencode "state=open" \
    --data-urlencode "head=${GITHUB_REPO_ORG}:${PR_BRANCH}" \
    "https://api.github.com/repos/${GITHUB_REPO_ORG}/${GITHUB_REPO_NAME}/pulls" 2>/dev/null || true; } )
  PR_POLL_HTTP_CODE="${PR_POLL_RESPONSE##*$'\n'}"
  if [[ "${PR_POLL_HTTP_CODE}" == "200" ]]; then
    PR_POLL_SUCCEEDED=1
    PR_URL=$(printf '%s\n' "${PR_POLL_RESPONSE%$'\n'*}" | \
      jq -r '.[0].html_url // empty' 2>/dev/null || true)
  else
    log "[error] github: PR poll attempt ${i} returned HTTP ${PR_POLL_HTTP_CODE:-<transport error>}"
  fi

  if [[ -n "${PR_URL}" ]]; then
    info "github: PR found at ${PR_URL}"
    break
  fi

  if [[ ${i} -lt ${PR_CHECK_MAX_ATTEMPTS} ]]; then
    debug "github: No PR found, waiting ${SLEEP_TIME} seconds before retry..."
    sleep "${SLEEP_TIME}"
    # Exponential backoff: double the sleep time for next iteration (capped at 120s)
    SLEEP_TIME=$((SLEEP_TIME * 2))
    if [[ ${SLEEP_TIME} -gt 120 ]]; then
      SLEEP_TIME=120
    fi
  fi
done
unset PR_POLL_TOKEN

# Slack: Send notification based on PR creation result
info "slack: sending notification for PR creation"
if [[ -z "${PR_URL}" ]]; then
  if [[ ${PR_POLL_SUCCEEDED} -eq 1 ]]; then
    notify "❌ Component updater job failed, no PR found after ${PR_CHECK_MAX_ATTEMPTS} attempts. Please check prow at ${PROW_JOB_URL}" || true
    error "github: No PR found after ${PR_CHECK_MAX_ATTEMPTS} attempts"
  fi
  notify "❌ Component updater job failed: the GitHub API rejected every PR poll (last HTTP ${PR_POLL_HTTP_CODE:-<transport error>}). Please check prow at ${PROW_JOB_URL}" || true
  error "github: PR poll failed with HTTP ${PR_POLL_HTTP_CODE:-<transport error>}; prcreator may have succeeded — check the repository directly"
fi

# Notification is best-effort: a mergeable PR already exists, so a broken
# webhook must not turn a successful run into a failed job.
notify "✅ Component version update PR ready to review: ${PR_URL}" || true
exit 0
