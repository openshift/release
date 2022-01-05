#!/bin/bash

# This is to satisfy shellcheck SC2153
export RELEASE_REPO=${RELEASE_REPO}

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

# Note: REPO_NAME and REPO_OWNER are not available in periodic type jobs. Prow docs link below.
# https://github.com/kubernetes/test-infra/blob/master/prow/jobs.md#job-environment-variables
# We wouldn't have the infromation needed to do the business logic in a periodic run.
if [[ "$JOB_TYPE" == "periodic" ]]; then
    log "ERROR Cannot update the manifest from a $JOB_TYPE job"
    exit 1
fi

# Check to see if running in openshift/release -> set DRY_RUN to true
if [[ "$REPO_OWNER" == "openshift" && "$REPO_NAME" == "release" ]]; then
    log "INFO Running in openshift/release, setting DRY_RUN to true"
    DRY_RUN="true"
fi

# Setup GitHub credentials
GITHUB_TOKEN_FILE="$SECRETS_PATH/$GITHUB_SECRET/$GITHUB_SECRET_FILE"
log "INFO Setting up git credentials."
if [[ ! -r "${GITHUB_TOKEN_FILE}" ]]; then
    log "ERROR GitHub token file missing or not readable: $GITHUB_TOKEN_FILE"
    exit 1
fi
GITHUB_TOKEN=$(cat "$GITHUB_TOKEN_FILE")
{
    echo "https://${GITHUB_USER}:${GITHUB_TOKEN}@${RELEASE_REPO}.git"
} >> ghcreds
git config --global credential.helper 'store --file=ghcreds'

# Set up repo URLs
release_url="https://${RELEASE_REPO}.git"

# Clone repos
release_dir="$HOME/release"

log "INFO Cloning the RELEASE_REPO: ${RELEASE_REPO} into ${release_dir}"
git clone "$release_url" "$release_dir" || {
    log "ERROR Could not clone release repo $release_url"
    exit 1
}

# There are alot of OSCI env variables to configure this is a way to configure 
# without mapping all of them directly in the step registry.
if [[ -n "${OSCI_ENV_CONFIG:-}" ]]; then
    readarray -t config <<< "${OSCI_ENV_CONFIG}"
    for var in "${config[@]}"; do
        if [[ -n "${var}" ]]; then
            echo "export ${var}" >> "${SHARED_DIR}/osci-env-config"
        fi
    done

    # We create this file above - Ignore SC1091
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/osci-env-config"
fi

# Determine current release branch
branch="${PULL_BASE_REF}"
log "INFO The base branch is $branch"

if [[ -n "$RELEASE_REF" ]]; then
    log "INFO RELEASE_REF variable is set. Using $RELEASE_REF for OSCI_COMPONENT_BRANCH."
    export OSCI_COMPONENT_BRANCH=${RELEASE_REF}
    log "INFO RELEASE_REF variable is set. Using $RELEASE_REF as branch."
    branch="${RELEASE_REF}"
fi

# Get current Z-stream version and set to OSCI_COMPONENT_VERSION
cd "$release_dir" || exit 1
git checkout "$branch" || {
    log "ERROR Could not checkout branch $branch in OCM release repo"
    exit 1
}
release=$(cat "$release_dir/Z_RELEASE_VERSION")
export OCSI_COMPONENT_VERSION=${release}
log "INFO Z-stream version is $release"

# Set OSCI_COMPONENT_NAME to REPO_NAME if it is not provided
export OSCI_COMPONENT_NAME=${OSCI_COMPONENT_NAME:-$REPO_NAME}
log "INFO OSCI_COMPONENT_NAME is ${OSCI_COMPONENT_NAME}."

# Set defaults for OCM pipeline and repo if not set.
export OSCI_PIPELINE_ORG=${OSCI_PIPELINE_ORG:-open-cluster-management}
export OSCI_IMAGE_REMOTE_REPO=${OSCI_IMAGE_REMOTE_REPO:-quay.io/open-cluster-management}
export OSCI_IMAGE_REMOTE_REPO_SRC=${OSCI_IMAGE_REMOTE_REPO_SRC:-registry.ci.openshift.org/open-cluster-management}

# Debug information
echo "INFO OSCI Environment variables are set to: "
env | grep OSCI

if [[ "$DRY_RUN" == "false" ]]; then
    # We check for postsubmit specifically because we need a new image published 
    # before running this step. Putting this check down here means that this step
    # is rehearsable in openshift/release.
    if [[ ! ("$JOB_TYPE" = "postsubmit" ) ]]; then
        log "ERROR Cannot update the manifest from a $JOB_TYPE job"
        exit 1
    fi

    # Run manifest update
    cd /opt/build-harness/build-harness-extensions/modules/osci/ || exit 1
    make osci/publish BUILD_HARNESS_EXTENSIONS_PATH=/opt/build-harness/build-harness-extensions
else
    log "INFO DRY_RUN is set to $DRY_RUN. Exiting without publishing changes to OCM manifest."
fi
