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

# Setup registry credentials
REGISTRY_TOKEN_FILE="$SECRETS_PATH/$REGISTRY_SECRET/$REGISTRY_SECRET_FILE"

if [[ ! -r "$REGISTRY_TOKEN_FILE" ]]; then
    log "ERROR Registry secret file not found: $REGISTRY_TOKEN_FILE"
    log "      SECRETS_PATH        : $SECRETS_PATH"
    log "      REGISTRY_SECRET     : $REGISTRY_SECRET"
    log "      REGISTRY_SECRET_FILE: $REGISTRY_SECRET_FILE"
    exit 1
fi

if [[ -z "$IMAGE_REPO" ]]; then
    log "ERROR IMAGE_REPO is empty"
    exit 1
fi

config_file="$HOME/.docker/config.json"
base64 -d < "$REGISTRY_TOKEN_FILE" | jq '{"auths": .}' > "$config_file" || {
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
