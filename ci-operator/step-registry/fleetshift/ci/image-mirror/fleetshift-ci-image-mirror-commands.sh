#!/bin/bash

export HOME=/tmp/home
mkdir -p "$HOME/.docker"
cd "$HOME" || exit 1

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

config_file="$HOME/.docker/config.json"
base64 -d <"$REGISTRY_TOKEN_FILE" >"$config_file" || {
    log "ERROR Could not base64 decode registry secret file"
    log "      From: $REGISTRY_TOKEN_FILE"
    log "      To  : $config_file"
    exit 1
}

# Get IMAGE_TAG if not provided
if [[ -z "$IMAGE_TAG" ]]; then
    case "$JOB_TYPE" in
    presubmit)
        log "INFO Building image tag for a $JOB_TYPE job"
        IMAGE_TAG="PR${PULL_NUMBER}-${PULL_PULL_SHA}"
        ;;
    postsubmit)
        log "INFO Building image tag for a $JOB_TYPE job"
        IMAGE_TAG="${PULL_BASE_SHA}"
        ;;
    *)
        log "ERROR Cannot publish an image from a $JOB_TYPE job"
        exit 1
        ;;
    esac
fi
log "INFO Image tag is $IMAGE_TAG"

# Build destination image reference
DESTINATION_IMAGE_REF="$REGISTRY_HOST/$REGISTRY_ORG/$IMAGE_REPO:$IMAGE_TAG"

log "INFO Mirroring Image"
log "     From: $SOURCE_IMAGE_REF"
log "     To  : $DESTINATION_IMAGE_REF"

mirror_log="${ARTIFACT_DIR}/oc-mirror-output.log"

for i in {1..6}; do
    if ! oc image mirror --keep-manifest-list=true "$SOURCE_IMAGE_REF" "$DESTINATION_IMAGE_REF" 1>${mirror_log}; then
        log "ERROR Unable to mirror image"
    fi

    if [[ -n "$(cat ${mirror_log})" ]]; then
        break
    fi

    log "WARN Nothing mirrored: oc image mirror log is empty."

    if [[ "${i}" == "6" ]]; then
        log "ERROR failed to complete mirroring"
        exit 1
    fi

    log "INFO Retrying (${i} of 5) ..."
    sleep 60
done

log "INFO Mirroring complete."
