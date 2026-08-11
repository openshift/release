#!/bin/bash

set -euo pipefail

dnf install -y git

HOME="$(mktemp -d -t ff-XXXXX)"
export HOME
cd

log_file="${ARTIFACT_DIR}/fastforward.log"
log() {
    echo "$(date --iso-8601=seconds)" "$@" | tee -a "$log_file"
}

# git_wrapper invokes the `git` CLI with
# - creds in a way that doesn't reveal them in logs, env, or process table.
# - logging
git_wrapper() {
  git -c credential.helper= -c credential.helper='!f() { echo username=openshift-merge-robot; printf password=; cat /etc/github/oauth; echo; }; f' "$@" 2>&1 | tee -a "$log_file"
}

log "INFO Fast-forward settings"
log "    REPO_OWNER         = $REPO_OWNER"
log "    REPO_NAME          = $REPO_NAME"
log "    SOURCE_BRANCH      = $SOURCE_BRANCH"
log "    DESTINATION_BRANCH = $DESTINATION_BRANCH"

repo_url="https://github.com/${REPO_OWNER}/${REPO_NAME}.git"

log "INFO Cloning $DESTINATION_BRANCH"
git_wrapper clone -b "$DESTINATION_BRANCH" "$repo_url"
cd "$REPO_NAME"

log "INFO Pulling $SOURCE_BRANCH into $DESTINATION_BRANCH (ff-only)"
git_wrapper pull --ff-only origin "$SOURCE_BRANCH"

log "INFO Pushing to origin/$DESTINATION_BRANCH"
git_wrapper push

log "INFO Fast-forward complete"
