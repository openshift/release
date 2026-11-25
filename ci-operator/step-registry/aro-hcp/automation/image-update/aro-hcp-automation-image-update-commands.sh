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
required_tools=(git az bicep yq jq curl)
for cmd in "${required_tools[@]}"; do
  command -v "${cmd}" &> /dev/null || error "required tool '${cmd}' is not installed or not in PATH."
done
debug "precheck: all required tools are present"

# Publication: fix the commit this run prepares from.
BASE_COMMIT="$(git rev-parse HEAD)"
readonly BASE_COMMIT
debug "publish: preparing from ${BASE_COMMIT}"

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

# Render: format YAML and regenerate helm fixtures
debug "render: running yaml formatting and updating helm fixtures"
run make yamlfmt
run make update-helm-fixtures

# Configuration: Materialize final configuration
info "image: materializing configuration"
run make -C config materialize

# Publication: collect the intended outputs and refuse anything else
info "publish: collecting the digest outputs"
PATHS_FILE="/tmp/image-updater-paths.txt"
BODY_FILE="/tmp/image-updater-pr.md"
: > "${PATHS_FILE}"
while IFS= read -r entry; do
  path="${entry:3}"
  case "${path}" in
    "tooling/image-updater/config.yaml"|config/*|*zz_fixture_TestHelmTemplate*)
      printf '%s\n' "${path}" >> "${PATHS_FILE}" ;;
    *)
      error "publish: unexpected change outside the digest outputs: ${path}" ;;
  esac
done < <(git status --porcelain)

if [[ ! -s "${PATHS_FILE}" ]]; then
  error "publish: the rendered outputs produced no publishable changes"
fi

{
  printf 'This automated PR updates ARO-HCP container image digests to the latest versions from registries.\n\n'
  cat "${IMAGE_UPDATER_OUTPUT}"
  printf '\n---\n**Schedule:** Monday through Friday at 2 AM UTC\n'
  printf '**Generated by:** [%s](%s)\n' "${JOB_NAME:-image-updater}" "${PROW_JOB_URL}"
  printf '**Generated at:** %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)"
} > "${BODY_FILE}"

# Git: Display changes for debugging
# Security Note: Only show diff in high debug mode; ensure no credential files are in the diff
if [[ ${VERBOSITY-0} -ge 2 ]]; then
  debug "publish: changes to be merged into ${GITHUB_REPO_BRANCH}"
  git diff "${BASE_COMMIT}"
fi

# GitHub: Publish the rolling pull request
info "github: publishing the pull request"
if ! receipt="$(./tooling/image-updater/image-updater publish \
  --repo . \
  --base "${GITHUB_REPO_BRANCH}" \
  --head-repo "${GITHUB_REPO_ORG}/${GITHUB_REPO_NAME}" \
  --base-commit "${BASE_COMMIT}" \
  --paths-file "${PATHS_FILE}" \
  --body-file "${BODY_FILE}" \
  --title "${GITHUB_PR_TITLE}" \
  --git-name "${GITHUB_PR_USER}" \
  --git-email "${GITHUB_PR_EMAIL}" \
  --app-id-file "${GITHUB_APP_ID_PATH}" \
  --app-key-file "${GITHUB_APP_KEY_PATH}")"; then
  notify "❌ Image digest updater job failed to publish the pull request. Please check prow at ${PROW_JOB_URL}"
  error "github: publish command failed"
fi

PR_URL="$(printf '%s' "${receipt}" | jq -r '.URL // empty')"
if [[ -z "${PR_URL}" ]]; then
  notify "❌ Image digest updater job published without a pull request URL. Please check prow at ${PROW_JOB_URL}"
  error "github: publish returned no pull request URL"
fi

notify "✅ Image digest update PR ready to review: ${PR_URL}"
exit 0
