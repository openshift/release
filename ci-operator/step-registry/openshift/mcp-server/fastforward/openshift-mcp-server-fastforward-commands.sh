#!/bin/bash

set -euo pipefail

tmp_dir=$(mktemp -d -t ff-XXXXX)
cd "$tmp_dir" || exit 1
export HOME="$tmp_dir"

log_file="${ARTIFACT_DIR}/fastforward.log"
log() {
    local ts
    ts=$(date --iso-8601=seconds)
    echo "$ts" "$@" | tee -a "$log_file"
}

log "INFO Fast-forward settings"
log "    REPO_OWNER         = $REPO_OWNER"
log "    REPO_NAME          = $REPO_NAME"
log "    SOURCE_BRANCH      = $SOURCE_BRANCH"
log "    DESTINATION_BRANCH = $DESTINATION_BRANCH"

if [[ -z "$DESTINATION_BRANCH" ]]; then
    log "ERROR DESTINATION_BRANCH may not be empty"
    exit 1
fi

token=$(cat /etc/github/oauth)
repo_url="https://openshift-merge-robot:${token}@github.com/${REPO_OWNER}/${REPO_NAME}.git"

log "INFO Cloning $DESTINATION_BRANCH"
if ! git clone -b "$DESTINATION_BRANCH" "$repo_url" 2>&1 | tee -a "$log_file"; then
    log "INFO $DESTINATION_BRANCH does not exist, creating from $SOURCE_BRANCH"
    if ! git clone -b "$SOURCE_BRANCH" "$repo_url" 2>&1 | tee -a "$log_file"; then
        log "ERROR Could not clone $SOURCE_BRANCH"
        exit 1
    fi
    cd "$REPO_NAME" || exit 1
    git checkout -b "$DESTINATION_BRANCH"
    git push -u origin "$DESTINATION_BRANCH" 2>&1 | tee -a "$log_file"
    log "INFO Created and pushed $DESTINATION_BRANCH"
    exit 0
fi

cd "$REPO_NAME" || exit 1

log "INFO Pulling $SOURCE_BRANCH into $DESTINATION_BRANCH (ff-only)"
if ! git pull --ff-only origin "$SOURCE_BRANCH" 2>&1 | tee -a "$log_file"; then
    log "ERROR Could not fast-forward from $SOURCE_BRANCH"
    exit 1
fi

log "INFO Pushing to origin/$DESTINATION_BRANCH"
if ! git push 2>&1 | tee -a "$log_file"; then
    log "ERROR Could not push to $DESTINATION_BRANCH"
    exit 1
fi

log "INFO Fast-forward complete"
