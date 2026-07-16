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

REGISTRY_TOKEN_FILE="$SECRETS_PATH/$REGISTRY_SECRET/$REGISTRY_SECRET_FILE"

if [[ ! -r "$REGISTRY_TOKEN_FILE" ]]; then
    log "ERROR Registry secret file not found or not readable"
    exit 1
fi

base64 -d <"$REGISTRY_TOKEN_FILE" >"$HOME/.docker/config.json" || {
    log "ERROR Could not decode registry secret"
    exit 1
}

if [[ -z "$IMAGE_TAG" ]]; then
    case "$JOB_TYPE" in
    presubmit)
        IMAGE_TAG="PR${PULL_NUMBER}-${PULL_PULL_SHA}"
        ;;
    postsubmit)
        IMAGE_TAG="${PULL_BASE_SHA}"
        ;;
    *)
        log "ERROR Cannot derive IMAGE_TAG for job type $JOB_TYPE"
        exit 1
        ;;
    esac
fi

mirror_image() {
    local tag="$1"
    local destination_image_ref="$REGISTRY_HOST/$REGISTRY_ORG/$IMAGE_REPO:$tag"
    local mirror_log
    mirror_log="$(mktemp)"

    log "INFO Mirroring $IMAGE_REPO:$tag"

    for i in {1..6}; do
        : >"$mirror_log"
        if oc image mirror --keep-manifest-list=true "$SOURCE_IMAGE_REF" "$destination_image_ref" 1>"$mirror_log" 2>/dev/null \
            && [[ -s "$mirror_log" ]]; then
            rm -f "$mirror_log"
            log "INFO Mirrored $IMAGE_REPO:$tag"
            return 0
        fi

        if [[ "${i}" == "6" ]]; then
            rm -f "$mirror_log"
            log "ERROR Failed to mirror $IMAGE_REPO:$tag"
            return 1
        fi

        log "WARN Mirror attempt $i failed; retrying in 60s"
        sleep 60
    done

    rm -f "$mirror_log"
}

if ! mirror_image "$IMAGE_TAG"; then
    exit 1
fi

if [[ "${ALSO_TAG_LATEST:-}" == "true" && "$IMAGE_TAG" != "latest" ]]; then
    if ! mirror_image "latest"; then
        exit 1
    fi
fi

log "INFO Done"
