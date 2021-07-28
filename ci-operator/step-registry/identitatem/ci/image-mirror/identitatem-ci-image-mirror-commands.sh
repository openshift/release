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

COMPONENT_REPO="github.com/${REPO_OWNER}/${REPO_NAME}"
component_url="https://${COMPONENT_REPO}.git"

# Clone repos
component_dir="$HOME/component"

git clone "$component_url" "$component_dir" || {
    log "ERROR Could not clone component repo $component_url"
    exit 1
}

release="$RELEASE_VERSION"
log "INFO Z-stream version is $release"

# Get IMAGE_REPO if not provided
if [[ -z "$IMAGE_REPO" ]]; then
    log "INFO Getting destination image repo name from COMPONENT_NAME"
    IMAGE_REPO=$(cat "${component_dir}/COMPONENT_NAME")
    log "     Image repo from COMPONENT_NAME is $IMAGE_REPO"
fi
log "INFO Image repo is $IMAGE_REPO"

# Get IMAGE_TAG if not provided
if [[ -z "$IMAGE_TAG" ]]; then
    case "$JOB_TYPE" in
        presubmit)
            log "INFO Building default image tag for a $JOB_TYPE job"
            IMAGE_TAG="${release}-PR${PULL_NUMBER}-${PULL_PULL_SHA}"
            ;;
        postsubmit)
            log "INFO Building default image tag for a $JOB_TYPE job"
            IMAGE_TAG="${release}-${PULL_BASE_SHA}"
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
base64 -d < "$REGISTRY_TOKEN_FILE" > "$config_file" || {
    log "ERROR Could not base64 decode registry secret file"
    log "      From: $REGISTRY_TOKEN_FILE"
    log "      To  : $config_file"
    exit 1
}

# Build destination image reference
DESTINATION_IMAGE_REF="$REGISTRY_HOST/$REGISTRY_ORG/$IMAGE_REPO:$IMAGE_TAG"

log "INFO Mirroring Image"
log "     From: $SOURCE_IMAGE_REF"
log "     To  : $DESTINATION_IMAGE_REF"
oc image mirror "$SOURCE_IMAGE_REF" "$DESTINATION_IMAGE_REF" || {
    log "ERROR Unable to mirror image"
    exit 1
}

log "INFO Mirroring complete."
