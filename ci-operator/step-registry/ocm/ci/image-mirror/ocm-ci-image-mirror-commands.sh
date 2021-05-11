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

# Setup GitHub credentials
GITHUB_TOKEN_FILE="$SECRETS_PATH/$GITHUB_SECRET/$GITHUB_SECRET_FILE"
log "Setting up git credentials."
if [[ ! -r "${GITHUB_TOKEN_FILE}" ]]; then
    log "ERROR GitHub token file missing or not readable: $GITHUB_TOKEN_FILE"
    exit 1
fi
GITHUB_TOKEN=$(cat "$GITHUB_TOKEN_FILE")
COMPONENT_REPO="github.com/${REPO_OWNER}/${REPO_NAME}"
{
    echo "https://${GITHUB_USER}:${GITHUB_TOKEN}@${COMPONENT_REPO}.git"
    echo "https://${GITHUB_USER}:${GITHUB_TOKEN}@${RELEASE_REPO}.git"
} >> ghcreds
git config --global credential.helper 'store --file=ghcreds'

# Set up repo URLs
component_url="https://${COMPONENT_REPO}.git"
release_url="https://${RELEASE_REPO}.git"

# Clone repos
component_dir="$HOME/component"
release_dir="$HOME/release"

git clone "$component_url" "$component_dir" || {
    log "ERROR Could not clone component repo $component_url"
    exit 1
}

git clone "$release_url" "$release_dir" || {
    log "ERROR Could not clone release repo $release_url"
    exit 1
}

# Determine current release branch
branch="${PULL_BASE_REF}"
log "INFO The base branch is $branch"

if [[ "$branch" == "main" || "$branch" == "master" ]]; then
    log "INFO Base branch is either main or master."
    log "     Need to get current release branch from release repo at $RELEASE_REPO"
    branch=$(cat "${release_dir}/CURRENT_RELEASE")
    log "     Branch from CURRENT_RELEASE is $branch"
fi

# Validate release branch. We can only run on release-x.y branches.
if [[ ! "$branch" =~ ^release-[0-9]+\.[0-9]+$ ]]; then
    log "ERROR Branch $branch is not a release branch."
    log "      Base branch of PR must match release-x.y"
    exit 1
fi

# Get current Z-stream version
cd "$release_dir" || exit 1
git checkout "$branch" || {
    log "ERROR Could not checkout branch $branch in release repo"
    exit 1
}
release=$(cat "$release_dir/Z_RELEASE_VERSION")
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
