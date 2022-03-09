#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator catalog publish command ************"

# Install tools
echo "## Install yq"
curl -L https://github.com/mikefarah/yq/releases/download/v4.13.5/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq
echo "   yq installed"

echo "## Install jq"
curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/jq && chmod +x /tmp/jq
echo "   jq installed"

# Setup registry credentials
REGISTRY_TOKEN_FILE="$SECRETS_PATH/$REGISTRY_SECRET/$REGISTRY_SECRET_FILE"
CI_REGISTRY_TOKEN_FILE="$SECRETS_PATH/$CI_REGISTRY_SECRET/$CI_REGISTRY_SECRET_FILE"

echo "## Setting up registry credentials."
mkdir -p "$HOME/.docker"
config_file="$HOME/.docker/config.json"

# Merge the two pull-secret files
jq --slurpfile quay "${REGISTRY_TOKEN_FILE}" '.auths = .auths * $quay[0].auths' "${CI_REGISTRY_TOKEN_FILE}" > "$config_file" || {
    echo "ERROR Could not read from at-least one of the registry secret files"
    echo "      From: $REGISTRY_TOKEN_FILE and ${CI_REGISTRY_TOKEN_FILE}"
    echo "      To  : $config_file"
}

if [[ ! -r "$REGISTRY_TOKEN_FILE" ]]; then
    echo "ERROR Registry config file not found: $REGISTRY_TOKEN_FILE"
    exit 1
fi

if [[ ! -r "$CI_REGISTRY_TOKEN_FILE" ]]; then
    echo "ERROR Registry config file not found: $CI_REGISTRY_TOKEN_FILE"
    exit 1
fi

sleep 5000

oc registry login

# Deep mirroring for the catalog
oc adm catalog mirror "${INDEX_IMAGE}" "${REGISTRY_HOST}/${REGISTRY_ORG}"

# The catalog is mirrored to an unpredictable name in quay, we need to extract
# that name from the generated catalog source
GENERATED_DIRECTORY=$(cd manifests-temp-* && pwd)
IMAGE_TO_MIRROR=$(/tmp/yq eval '.spec.image' "${GENERATED_DIRECTORY}/catalogSource.yaml")

# ... And then push it to the tag we actually want
MIRROR_DESTINATION="${REGISTRY_HOST}/${REGISTRY_ORG}/${REGISTRY_CATALOG_REPOSITORY_NAME}:${REGISTRY_CATALOG_REPOSITORY_TAG}"
oc image mirror "${IMAGE_TO_MIRROR}" "${MIRROR_DESTINATION}"

echo "## Done ##"
