#!/bin/bash

export HOME=/tmp/home
mkdir -p "$HOME/.docker"
cd "$HOME" || exit 1

# log function
log_file="${ARTIFACT_DIR}/mirror.log"
log() {
    local ts
    ts=$(date --iso-8601=seconds)
    echo "$ts" "$@" | tee -a "$log_file"
}

# Get current date
current_date=$(date +%F)
log "INFO Current date is $current_date"

# Get RELEASE_VERSION
log "INFO Z-stream version is $RELEASE_VERSION"

# Get IMAGE_REPO
log "INFO Image repo is $IMAGE_REPO"

# Get IMAGE_TAG if not provided
if [[ -z "$IMAGE_TAG" ]]; then
    case "$JOB_TYPE" in
        presubmit)
            log "INFO Building default image tag for a $JOB_TYPE job"
            IMAGE_TAG="pr-${PULL_NUMBER}"
            ;;
        postsubmit)
            log "INFO Building default image tag for a $JOB_TYPE job"
            IMAGE_TAG="${RELEASE_VERSION}-${PULL_BASE_SHA:0:7}"
            IMAGE_FLOATING_TAG="${RELEASE_VERSION}"
            ;;
        periodic)
            log "INFO Building default image tag for a $JOB_TYPE job"
            IMAGE_TAG="${RELEASE_VERSION}-nightly-${current_date}"
            ;;
        *)
            log "ERROR Cannot publish an image from a $JOB_TYPE job"
            exit 1
            ;;
    esac
fi
log "INFO Image tag is $IMAGE_TAG"

# Setup registry credentials
REGISTRY_TOKEN_FILE="$SECRETS_PATH/$REGISTRY_SECRET/$REGISTRY_SECRET_FILE"

if [[ ! -r "$REGISTRY_TOKEN_FILE" ]]; then
    log "ERROR Registry secret file not found: $REGISTRY_TOKEN_FILE"
    exit 1
fi

config_file="$HOME/.docker/config.json"
cp $REGISTRY_TOKEN_FILE $config_file || {
    log "ERROR Could not create registry secret file"
    log "    From: $REGISTRY_TOKEN_FILE"
    log "    To  : $config_file"
    exit 1
}

# Allow to pull images from internal Openshift CI registry
oc registry login || {
    log "ERROR Unable to login to internal Openshift CI registry"
    exit 1
}

# Check if running in openshift/release only in presubmit jobs because
# REPO_OWNER and REPO_NAME are not available for other types
dry=false
if [[ "$JOB_TYPE" == "presubmit" ]]; then
    if [[ "$REPO_OWNER" == "openshift" && "$REPO_NAME" == "release" ]]; then
        log "INFO Running in openshift/release, setting dry-run to true"
        dry=true
    fi
fi

# Build destination image reference
DESTINATION_REGISTRY_REPO="$REGISTRY_HOST/$REGISTRY_ORG/$IMAGE_REPO"
DESTINATION_IMAGE_REF="$DESTINATION_REGISTRY_REPO:$IMAGE_TAG"
if [[ -n "${IMAGE_FLOATING_TAG-}" ]]; then
    FLOATING_IMAGE_REF="$DESTINATION_REGISTRY_REPO:$IMAGE_FLOATING_TAG"
    DESTINATION_IMAGE_REF="$DESTINATION_IMAGE_REF $FLOATING_IMAGE_REF"
fi

log "INFO Mirroring Image"
log "    From   : $SOURCE_IMAGE_REF"
log "    To     : $DESTINATION_IMAGE_REF"
log "    Dry Run: $dry"
oc image mirror $SOURCE_IMAGE_REF $DESTINATION_IMAGE_REF --dry-run=$dry || {
    log "ERROR Unable to mirror image"
    exit 1
}

log "INFO Mirroring complete."
