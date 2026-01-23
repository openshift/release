#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# ============================================================================
# SECURITY WARNING: This script handles sensitive credentials
# ============================================================================
# - GitHub tokens (GITHUB_TOKEN)
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

# ShellCheck directives
# shellcheck disable=SC2034  # Unused variables are exported for external tools

# Environment variable defaults (overridable via ref.yaml)
VERBOSITY=${VERBOSITY:-1}

# Internal variables (not configurable via ref.yaml)
readonly IMAGE_UPDATER_OUTPUT="/tmp/image-updater-output.md"
readonly IMAGE_UPDATER_OUTPUT_FORMAT="markdown"

# Logging functions with timestamps and severity levels
log() { echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] ${*}"; }
info()  { if [[ ${VERBOSITY-0} -ge 1 ]]; then log "[info] ${*}"; fi }
debug() { if [[ ${VERBOSITY-0} -ge 2 ]]; then log "[debug] ${*}"; fi }
error() { log "[error] ${*}"; exit ${ERR_EXIT_CODE:-1}; }


# Cleanup function to handle failures gracefully
cleanup() {
  readonly EXIT_CODE=${?}
  if [[ ${EXIT_CODE} -ne 0 ]]; then
    notify "❌ Image digest updater job failed with exit code ${EXIT_CODE}. Please check prow at ${PROW_JOB_URL:-https://prow.ci.openshift.org}"
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
  if ! curl -f -s -X POST -H 'Content-type: application/json' \
    --data "{\"text\":\"${*}\"}" "${webhook_url}" 2>/dev/null; then
    error "slack: failed to send Slack notification"
  fi

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
required_tools=(skopeo git az bicep yq jq curl)
for cmd in "${required_tools[@]}"; do
  command -v "${cmd}" &> /dev/null || error "required tool '${cmd}' is not installed or not in PATH."
done
debug "precheck: all required tools are present"

# Configuration: Load GitHub token from file
debug "cfg: loading GitHub token"
if [[ ! -f "${GITHUB_TOKEN_PATH}" ]]; then
  error "github: token file not found at ${GITHUB_TOKEN_PATH}"
fi

# Security: Load token without printing it
GITHUB_TOKEN=$(cat "${GITHUB_TOKEN_PATH}")
readonly GITHUB_TOKEN
debug "cfg: GitHub token loaded successfully (content redacted)"

# Git: Configure git user and email for commits
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

debug "azure: authentication configured successfully (credentials redacted)"

# Image Updater: Build and run the image-updater tool
info "image: fetching the latest image digests for all components"
make image-updater OUTPUT_FILE="${IMAGE_UPDATER_OUTPUT}" OUTPUT_FORMAT="${IMAGE_UPDATER_OUTPUT_FORMAT}"

# Check if there are any changes from image updates
if [[ $(git status --porcelain) == "" ]]; then
  info "image: no new digests found for any component images"
  notify "⚠️ Image digest updater job completed but no new digests found for any component images. Please check prow at ${PROW_JOB_URL}"
  exit 0
else 
  info "image: new digests found for some component images"
  if [[ ${VERBOSITY-0} -ge 1 ]]; then cat ${IMAGE_UPDATER_OUTPUT}; echo; fi
fi

# Git: Commit updated image digests
info "git: committing updated image digests"
git commit --all --quiet --message "chore: execute image-updater for all components"

# ACM: Render ACM helm-charts
info "acm: rendering ACM helm-charts"
run make -C acm helm-charts

# Render helm chart
debug "acm: running yaml formatting and updating helm fixtures"
run make yamlfmt
run make update-helm-fixtures

# Check if helm chart rendering produced changes
if [[ $(git status --porcelain) != "" ]]; then
  info "git: committing rendered helm charts"
  git commit --all --quiet --message "chore: render ACM helm-charts"
else
  info "acm: no changes after helm chart rendering and formatting"
fi

# Configuration: Materialize final configuration
info "image: materializing configuration"
run make -C config materialize

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
  -github-token-path="${GITHUB_TOKEN_PATH}" \
  -organization="${GITHUB_REPO_ORG}" \
  -repo="${GITHUB_REPO_NAME}" \
  -branch="${GITHUB_REPO_BRANCH}" \
  -git-message="chore: render digests using materialize" \
  -pr-title="${GITHUB_PR_TITLE}" \
  -pr-message="This automated PR updates ARO-HCP container image digests to the latest versions from registries.

$(cat "${IMAGE_UPDATER_OUTPUT}")

---
**Schedule:** Monday through Friday at 2 AM UTC
**Generated by:** [periodic-ci-Azure-ARO-HCP-main-image-updater-tooling](${PROW_JOB_URL})
**Generated at:** $(date +%Y-%m-%dT%H:%M:%S%z)
"
prcreator_exit_code=${?}
set -o errexit

# Verify prcreator succeeded
if [[ ${prcreator_exit_code} -ne 0 ]]; then
  notify "❌ Image digest updater job failed to create PR. Please check prow at ${PROW_JOB_URL}"
  error "github: prcreator command failed with exit code ${prcreator_exit_code}"
fi

# GitHub: Poll for PR creation with exponential backoff
info "github: checking for existing PR"

readonly PR_CHECK_MAX_ATTEMPTS=${PR_CHECK_MAX_ATTEMPTS:-8}
SLEEP_TIME=10  # Start with 10 seconds

for ((i=1; i<=PR_CHECK_MAX_ATTEMPTS; i++)); do
  debug "github: attempting to find PR (attempt ${i} of ${PR_CHECK_MAX_ATTEMPTS})"

  # Security: Use authenticated API call with silent mode to prevent token exposure
  PR_URL=$(curl -f -s -H "Authorization: token ${GITHUB_TOKEN}" \
    "https://api.github.com/repos/Azure/ARO-HCP/pulls?per_page=100" 2>/dev/null | \
    jq -r ".[] | select(.user.login == \"${GITHUB_PR_USER}\" and .title == \"${GITHUB_PR_TITLE}\") | .html_url" | \
    head -1)

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
  notify "❌ Image digest updater job failed, no PR found after ${PR_CHECK_MAX_ATTEMPTS} attempts. Please check prow$ at ${PROW_JOB_URL}"
  error "github: No PR found after ${PR_CHECK_MAX_ATTEMPTS} attempts"
fi

notify "✅ Image digest update PR ready to review: ${PR_URL}"
exit 0
