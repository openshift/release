#!/bin/bash

export HOME=/tmp/home
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}/containers"
cd "$HOME" || exit 1

# log function
log_file="${ARTIFACT_DIR}/catalog-source.log"
log() {
    local ts
    ts=$(date --iso-8601=seconds)
    echo "$ts" "$@" | tee -a "$log_file"
}

# Get current date
current_date=$(date +%F)
log "INFO Current date is $current_date"

# Get IMAGE_REPO
log "INFO Image repo is $IMAGE_REPO"

# Get BUNDLE_IMAGE_TAG
log "INFO Bundle Image Tag is $BUNDLE_IMAGE_TAG"

# Get CATALOG_IMAGE_TAG
log "INFO Catalog Image Tag is $CATALOG_IMAGE_TAG"

# Get IMAGE_TAG
log "INFO Image Tag is $IMAGE_TAG"

# Build destination references
DESTINATION_REGISTRY_REPO_ORG="$REGISTRY_HOST/$REGISTRY_ORG"
DESTINATION_IMAGE_REF="$DESTINATION_REGISTRY_REPO/$IMAGE_REPO:$IMAGE_TAG"
DESTINATION_BUNDLE_IMAGE_REF="$DESTINATION_REGISTRY_REPO/$BUNDLE_IMAGE_REPO:$IMAGE_TAG"
DESTINATION_CATALOG_IMAGE_REF="$DESTINATION_REGISTRY_REPO/CATALOG_IMAGE_REPO:$IMAGE_TAG"

log "INFO Mirroring Image"
log "    From   : $SOURCE_IMAGE_REF"
log "    To     : $DESTINATION_IMAGE_REF"
log "    Dry Run: $dry"
oc image mirror $SOURCE_IMAGE_REF $DESTINATION_IMAGE_REF --dry-run=$dry || {
    log "ERROR Unable to mirror image"
    exit 1
}

log "INFO Mirroring complete."
