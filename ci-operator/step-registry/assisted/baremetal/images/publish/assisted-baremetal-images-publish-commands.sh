#!/bin/bash

export HOME=/tmp/home
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}/containers"
cd "$HOME" || exit 1

# If this is a periodic type job then we need to populate repo metadata from the JOB_SPEC
if [[ "$JOB_TYPE" == "periodic" ]]; then
    echo "INFO JOB_TYPE is: $JOB_TYPE populating repo metadata from JOB_SPEC"

    REPO_OWNER=$(echo ${JOB_SPEC} | jq -r '.extra_refs[].org')
    REPO_NAME=$(echo ${JOB_SPEC} | jq -r '.extra_refs[].repo')
    PULL_BASE_REF=$(echo ${JOB_SPEC} | jq -r '.extra_refs[].base_ref')
fi

#   Uncomment the below to test JQ commands
# REPO_OWNER_TEST=$(echo ${JOB_SPEC} | jq -r '.extra_refs[].org')
# REPO_NAME_TEST=$(echo ${JOB_SPEC} | jq -r '.extra_refs[].repo')
# PULL_BASE_REF_TEST=$(echo ${JOB_SPEC} | jq -r '.extra_refs[].base_ref')
# echo "JQ TEST: ${REPO_OWNER_TEST} ${REPO_NAME_TEST} ${PULL_BASE_REF_TEST}"
# echo ${JOB_SPEC}

echo "INFO The repository owner is ${REPO_OWNER}."
echo "INFO The repository name is ${REPO_NAME}."
echo "INFO The base branch is ${PULL_BASE_REF}."

# Get IMAGE_REPO if not provided
if [[ -z "$IMAGE_REPO" ]]; then
    echo "INFO Getting destination image repo name from REPO_NAME"
    IMAGE_REPO=${REPO_NAME}
    echo "     Image repo from REPO_NAME is $IMAGE_REPO"
fi
echo "INFO Image repo is $IMAGE_REPO"

current_date=$(date +%F)
echo "INFO Current date is: $current_date"

# Get IMAGE_TAG if not provided
if [[ -z "$IMAGE_TAG" ]]; then
    case "$JOB_TYPE" in
        presubmit)
            echo "INFO Building default image tag for a $JOB_TYPE job"
            IMAGE_TAG="${RELEASE_TAG_PREFIX}-PR${PULL_NUMBER}-${PULL_PULL_SHA}"
            ;;
        postsubmit)
            echo "INFO Building default image tag for a $JOB_TYPE job"
            IMAGE_TAG="${RELEASE_TAG_PREFIX}-${PULL_BASE_SHA}"
            ;;
        periodic)
            echo "INFO Building default image tag for a $JOB_TYPE job"
            IMAGE_TAG="${RELEASE_TAG_PREFIX}-${current_date}"

            # Make the daily image also accessible through just the prefix
            EXTRA_TAG="${RELEASE_TAG_PREFIX}"
            ;;
        *)
            echo "ERROR Cannot publish an image from a $JOB_TYPE job"
            exit 1
            ;;
    esac
fi
echo "INFO Image tag is $IMAGE_TAG"

# Setup registry credentials
REGISTRY_TOKEN_FILE="$SECRETS_PATH/$REGISTRY_SECRET/$REGISTRY_SECRET_FILE"

# we need to store credentials in $HOME/.docker/config.json for pre 4.10 oc
config_file="$HOME/.docker/config.json"
mkdir -p "$HOME/.docker"
cat "$REGISTRY_TOKEN_FILE" > "$config_file" || {
    echo "ERROR Could not read registry secret file"
    echo "      From: $REGISTRY_TOKEN_FILE"
    echo "      To  : $config_file"
}

if [[ ! -r "$REGISTRY_TOKEN_FILE" ]]; then
    echo "ERROR Registry authentication file not found: $REGISTRY_TOKEN_FILE"
    echo "      Is the $config_file in a different location?"
    exit 1
fi

echo "INFO Login to internal Openshift CI registry"
oc registry login

dry=false
# Check if running in openshift/release
if [[ "$REPO_OWNER" == "openshift" && "$REPO_NAME" == "release" ]]; then
    echo "INFO Running in openshift/release, setting dry-run to true"
    dry=true
fi

# Build destination image reference
DESTINATION_IMAGE_REF="$REGISTRY_HOST/$REGISTRY_ORG/$IMAGE_REPO:$IMAGE_TAG"

# Build mirror options
MIRROR_OPTS=""
if [[ "${KEEP_MANIFEST_LIST:-false}" == "true" ]]; then
    echo "INFO Multi-arch mode enabled: preserving manifest lists"
    MIRROR_OPTS="--keep-manifest-list=true"
fi

echo "INFO Image mirroring command is:"
echo "     oc image mirror ${SOURCE_IMAGE_REF} ${DESTINATION_IMAGE_REF} ${MIRROR_OPTS} --dry-run=$dry"

echo "INFO Mirroring Image"
echo "     From   : $SOURCE_IMAGE_REF"
echo "     To     : $DESTINATION_IMAGE_REF"
echo "     Dry Run: $dry"
oc image mirror "$SOURCE_IMAGE_REF" "$DESTINATION_IMAGE_REF" ${MIRROR_OPTS} --dry-run=$dry || {
    echo "ERROR Unable to mirror image"
    exit 1
}

# tag the image with its own digest to ensure the image can always be pulled by digest even if $IMAGE_TAG is updated.
if [[ "${KEEP_MANIFEST_LIST:-false}" == "true" ]]; then
    # Multi-arch mode: use --show-multiarch to get listDigest
    IMAGE_DIGEST_TAG=$(oc image info "${SOURCE_IMAGE_REF}" --show-multiarch -o json | jq -r 'if type == "array" then (.[0].listDigest | capture(".+:(?<digest>.+)").digest) else (.digest | capture(".+:(?<digest>.+)").digest) end')
else
    # Single-arch mode: use old command for backward compatibility (error messages go to stderr naturally)
    IMAGE_DIGEST_TAG=$(oc image info "${SOURCE_IMAGE_REF}" -o json | jq -r '(.digest | capture(".+:(?<digest>.+)").digest)')
fi

if [[ -z "${IMAGE_DIGEST_TAG}" ]] || [[ "${IMAGE_DIGEST_TAG}" == "null" ]]; then
    echo "ERROR Unable to get image digest"
    echo "      If source is multi-arch, set KEEP_MANIFEST_LIST=true"
    exit 1
fi

DIGEST_TAG_DESTINATION_IMAGE_REF="${REGISTRY_HOST}/${REGISTRY_ORG}/${IMAGE_REPO}:${IMAGE_DIGEST_TAG}"
oc image mirror "${SOURCE_IMAGE_REF}" "${DIGEST_TAG_DESTINATION_IMAGE_REF}" ${MIRROR_OPTS} --dry-run=$dry || {
    echo "ERROR Unable to mirror image"
    exit 1
}

if [[ ${EXTRA_TAG:-} != "" ]]; then
    EXTRA_TAG_DESTINATION_IMAGE_REF="$REGISTRY_HOST/$REGISTRY_ORG/$IMAGE_REPO:$EXTRA_TAG"
    oc image mirror "$DESTINATION_IMAGE_REF" "$EXTRA_TAG_DESTINATION_IMAGE_REF" ${MIRROR_OPTS} --dry-run=$dry || {
        echo "ERROR Unable to mirror image"
        exit 1
    }
fi

echo "INFO Mirroring complete."
