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
    exit 1
fi

# ocm-ci-image-mirror-setup resolves these and writes them for this step.
# Prefer those files over this step's defaults.
if [[ -f "${SHARED_DIR}/IMAGE_REPO" ]]; then
    IMAGE_REPO=$(cat "${SHARED_DIR}/IMAGE_REPO")
    log "INFO IMAGE_REPO from SHARED_DIR is $IMAGE_REPO"
fi
if [[ -f "${SHARED_DIR}/IMAGE_TAG" ]]; then
    IMAGE_TAG=$(cat "${SHARED_DIR}/IMAGE_TAG")
    log "INFO IMAGE_TAG from SHARED_DIR is $IMAGE_TAG"
fi

# Fail if IMAGE_REPO or IMAGE_TAG is empty.
if [[ -z "$IMAGE_REPO" ]]; then
    log "ERROR IMAGE_REPO is empty"
    exit 1
fi
if [[ -z "$IMAGE_TAG" ]]; then
    log "ERROR IMAGE_TAG is empty"
    exit 1
fi

config_file="$HOME/.docker/config.json"
base64 -d <"$REGISTRY_TOKEN_FILE" >"$config_file" || {
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

mirror_log="${ARTIFACT_DIR}/oc-mirror-output.log"

for i in {1..6}; do
    if ! oc image mirror --keep-manifest-list=true "$SOURCE_IMAGE_REF" "$DESTINATION_IMAGE_REF" 1>"${mirror_log}"; then
        log "ERROR Unable to mirror image"
    elif [[ -n "$(cat "${mirror_log}")" ]]; then
        break
    else
        # The stdout output of `oc image mirror` is:
        # <sha> <image-repo>:<tag>
        # If it's empty, it's probable nothing was mirrored
        log "WARN Nothing mirrored: oc image mirror log is empty."
    fi

    if [[ "${i}" == "6" ]]; then
        log "ERROR failed to complete mirroring"
        exit 1
    fi

    log "INFO Retrying (${i} of 5) ..."
    sleep 60
done

log "INFO Mirroring complete."
