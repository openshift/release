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
error() { log "[error] ${*}"; exit ${ERR_EXIT_CODE:-1}; }


# Cleanup function to handle failures gracefully
# Track whether a Slack notification has already been sent for this run, so
# the EXIT-trap cleanup below does not send a second, generic failure message
# after an explicit one (e.g. from a prcreator or PR-poll failure path).
NOTIFIED=0

cleanup() {
  readonly EXIT_CODE=${?}
  if [[ ${EXIT_CODE} -ne 0 && ${NOTIFIED} -eq 0 ]]; then
    notify "❌ Component updater job failed with exit code ${EXIT_CODE}. Please check prow at ${PROW_JOB_URL:-https://prow.ci.openshift.org}"
    error "Script failed with exit code ${EXIT_CODE}. Cleaning up..."
  fi
}
trap cleanup EXIT

# Notify function with error handling for Slack notifications
notify() {

  if [[ ! -f "${SLACK_WEBHOOK_PATH}" ]]; then
    error "slack: webhook file not found at ${SLACK_WEBHOOK_PATH}"
  fi

  local webhook_url
  webhook_url=$(cat "${SLACK_WEBHOOK_PATH}") || {
    error "slack: failed to read Slack webhook file"
  }

  # Security: Use silent curl to prevent webhook URL exposure in logs
  # Timeouts bound a stalled webhook so cleanup cannot hang until the job timeout.
  if ! curl -f -s --connect-timeout 10 --max-time 30 -X POST -H 'Content-type: application/json' \
    --data "{\"text\":\"${*}\"}" "${webhook_url}" 2>/dev/null; then
    error "slack: failed to send Slack notification"
  fi

  NOTIFIED=1
  debug "slack: notification sent successfully"

}

# Helper function to run commands with conditional verbosity
# Security Note: In VERBOSITY mode (>=2), command output is visible. Ensure no sensitive
# data is passed through commands executed via this function.
run() {
  if [[ ${VERBOSITY-0} -ge 2 ]]; then
    "$@"
  else
    "$@" > /dev/null 2>&1
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

# Git: Commit updated component versions (config + rendered configs + fixtures)
info "git: committing updated component versions"
git commit --all --quiet --message "chore: execute component-updater for ${COMPONENT}"

# Git: Display changes for debugging
# Security Note: Only show diff in high debug mode; ensure no credential files are in the diff
if [[ ${VERBOSITY-0} -ge 2 ]]; then
  debug "git: changes to be merged into main"
  git diff main
fi

# GitHub: Create Pull Request using prcreator
info "git: creating the pull request"

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
  -pr-title="${GITHUB_PR_TITLE}" \
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
if [[ ${prcreator_exit_code} -ne 0 ]]; then
  notify "❌ Component updater job failed to create PR. Please check prow at ${PROW_JOB_URL}"
  error "github: prcreator command failed with exit code ${prcreator_exit_code}"
fi

# GitHub: Poll for PR with exponential backoff
info "github: checking for existing PR"

readonly PR_CHECK_MAX_ATTEMPTS=${PR_CHECK_MAX_ATTEMPTS:-8}
SLEEP_TIME=10  # Start with 10 seconds

for ((i=1; i<=PR_CHECK_MAX_ATTEMPTS; i++)); do
  debug "github: attempting to find PR (attempt ${i} of ${PR_CHECK_MAX_ATTEMPTS})"

  # Treat a failed poll (transport error or bad JSON) as an unsuccessful
  # attempt instead of letting errexit fail the job; the retry loop masks it.
  PR_URL=$( { curl -s --connect-timeout 10 --max-time 30 "https://api.github.com/repos/${GITHUB_REPO_ORG}/${GITHUB_REPO_NAME}/pulls?state=open&per_page=100" 2>/dev/null || true; } | \
    jq -r ".[] | select(.title == \"${GITHUB_PR_TITLE}\") | .html_url" 2>/dev/null | head -1 || true)

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

# Slack: Send notification based on PR creation result
info "slack: sending notification for PR creation"
if [[ -z "${PR_URL}" ]]; then
  notify "❌ Component updater job failed, no PR found after ${PR_CHECK_MAX_ATTEMPTS} attempts. Please check prow at ${PROW_JOB_URL}"
  error "github: No PR found after ${PR_CHECK_MAX_ATTEMPTS} attempts"
fi

notify "✅ Component version update PR ready to review: ${PR_URL}"
exit 0
