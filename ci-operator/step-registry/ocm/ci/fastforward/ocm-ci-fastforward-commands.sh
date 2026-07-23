#!/bin/bash

shopt -s extglob

ocm_dir=$(mktemp -d -t ocm-XXXXX)
cd "$ocm_dir" || exit 1
export HOME="$ocm_dir"

log_file="${ARTIFACT_DIR}/deploy.log"
log() {
    local ts
    ts=$(date --iso-8601=seconds)
    echo "$ts" "$@" | tee -a "$log_file"
}

log "INFO Checking settings"
log "    REPO_OWNER         = $REPO_OWNER"
log "    REPO_NAME          = $REPO_NAME"
log "    JOB_TYPE           = $JOB_TYPE"
log "    GITHUB_USER        = $GITHUB_USER"
log "    GITHUB_TOKEN_FILE  = $GITHUB_TOKEN_FILE"
log "    SOURCE_BRANCH      = $SOURCE_BRANCH"
log "    DESTINATION_BRANCH = $DESTINATION_BRANCH"

if [[ "$REPO_OWNER" == "openshift" ]]; then
    log "INFO This test is being run as a rehearsal. Exiting"
    exit 0
fi

if [[ "$JOB_TYPE" != "postsubmit" ]]; then
    log "ERROR This workflow may only be run as a postsubmit job"
    exit 1
fi

if [[ -z "$GITHUB_USER" ]]; then
    log "ERROR GITHUB_USER may not be empty"
    exit 1
fi

if [[ ! -r "${GITHUB_TOKEN_FILE}" ]]; then
    log "ERROR GITHUB_TOKEN_FILE missing or not readable"
    exit 1
fi

if [[ -z "$SOURCE_BRANCH" ]]; then
    log "ERROR SOURCE_BRANCH may not be empty"
    exit 1
fi

if [[ -z "$DESTINATION_BRANCH" ]]; then
    log "ERROR DESTINATION_BRANCH may not be empty"
    exit 1
fi

log "INFO Cloning DESTINATION_BRANCH"
token=$(cat "$GITHUB_TOKEN_FILE")
repo="github.com/$REPO_OWNER/$REPO_NAME"
repo_url="https://${GITHUB_USER}:${token}@${repo}.git"

if ! git clone -b "$DESTINATION_BRANCH" "$repo_url" ; then
    log "INFO DESTINATION_BRANCH does not exist. Will create it"
    log "INFO Cloning SOURCE_BRANCH"
    if ! git clone -b "$SOURCE_BRANCH" "$repo_url" ; then
        log "ERROR Could not clone SOURCE_BRANCH"
        log "      repo_url = $repo_url"
        exit 1
    fi

    log "INFO Changing into repo directory"
    cd "$REPO_NAME" || exit 1

    log "INFO Checking out new DESTINATION_BRANCH"
    if ! git checkout -b "$DESTINATION_BRANCH" ; then
        log "ERROR Could not checkout DESTINATION_BRANCH"
        exit 1
    fi

    log "INFO Pushing DESTINATION_BRANCH to origin"
    if ! git push -u origin "$DESTINATION_BRANCH" ; then
        log "ERROR Could not push to origin DESTINATION_BRANCH"
        exit 1
    fi

    log "INFO Fast forward complete"
    exit 0
fi

log "INFO Changing into repo directory"
cd "$REPO_NAME" || exit 1

log "INFO Pulling from SOURCE_BRANCH into DESTINATION_BRANCH"
if ! git pull --ff-only origin "$SOURCE_BRANCH" ; then
    log "ERROR Could not pull from SOURCE_BRANCH"
    exit 1
fi

log "INFO Pushing to origin/DESTINATION_BRANCH"
if ! git push ; then
    log "ERROR Could not push to DESTINATION_BRANCH"
    exit 1
fi

log "INFO Fast forward complete"

