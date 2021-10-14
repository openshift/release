#!/bin/bash

export HOME=/tmp/home
mkdir -p "$HOME/.docker"
cd "$HOME" || exit 1

# log function
log_file="${ARTIFACT_DIR}/manifest-update.log"
log() {
    local ts
    ts=$(date --iso-8601=seconds)
    echo "$ts" "$@" | tee -a "$log_file"
}

# Check for postsubmit job type
if [[ ! ("$JOB_TYPE" = "postsubmit" ) ]]; then
    log "ERROR Cannot update the manifest from a $JOB_TYPE job"
    exit 1
fi

# Setup GitHub credentials
GITHUB_TOKEN_FILE="$SECRETS_PATH/$GITHUB_SECRET/$GITHUB_SECRET_FILE"
log "Setting up git credentials."
if [[ ! -r "${GITHUB_TOKEN_FILE}" ]]; then
    log "ERROR GitHub token file missing or not readable: $GITHUB_TOKEN_FILE"
    exit 1
fi
GITHUB_TOKEN=$(cat "$GITHUB_TOKEN_FILE")
COMPONENT_REPO="github.com/${REPO_OWNER}/${REPO_NAME}"
{
    echo "https://${GITHUB_USER}:${GITHUB_TOKEN}@${RELEASE_REPO}.git"
} >> ghcreds
git config --global credential.helper 'store --file=ghcreds'

# Set up repo URLs
release_url="https://${RELEASE_REPO}.git"

# Clone repos
release_dir="$HOME/release"

git clone "$release_url" "$release_dir" || {
    log "ERROR Could not clone release repo $release_url"
    exit 1
}

# There are alot of OSCI env variables to configure this is a way to configure 
# without mapping all of them directly in the step registry.
if [[ -n "${OSCI_ENV_CONFIG:-}" ]]; then
  readarray -t config <<< "${OSCI_ENV_CONFIG}"
  for var in "${config[@]}"; do
    if [[ ! -z "${var}" ]]; then
      echo "export ${var}" >> "${SHARED_DIR}/osci-env-config"
    fi
  done
fi

source "${SHARED_DIR}/osci-env-config"

# Determine current release branch
branch="${PULL_BASE_REF}"
log "INFO The base branch is $branch"

if [[ -n "$RELEASE_REF" ]]; then
    log "INFO RELEASE_REF variable is set. Using $RELEASE_REF for OSCI_COMPONENT_BRANCH."
    export OSCI_COMPONENT_BRANCH=${RELEASE_REF}
fi

# Get current Z-stream version and set to OSCI_COMPONENT_VERSION
cd "$release_dir" || exit 1
git checkout "$branch" || {
    log "ERROR Could not checkout branch $branch in release repo"
    exit 1
}
release=$(cat "$release_dir/Z_RELEASE_VERSION")
export OCSI_COMPONENT_VERSION=${release}
log "INFO Z-stream version is $release"

# Set OSCI_COMPONENT_NAME to REPO_NAME if it is not provided
export OSCI_COMPONENT_NAME=${$OSCI_COMPONENT_NAME:-$REPO_NAME}

# Run manifest update
cd /opt/build-harness/build-harness-extensions/modules/osci/
make osci/publish BUILD_HARNESS_EXTENSIONS_PATH=/opt/build-harness/build-harness-extensions
