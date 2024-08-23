#!/bin/bash

# Exit the script on any error
set -e

# Start Docker daemon in the background
dockerd-entrypoint.sh &

# Wait for Docker daemon to fully start
sleep 10

# Enable Buildx for multi-platform builds
docker buildx create --use

# Log in to the registry
docker login -u $(cat ${SECRETS_PATH}/${REGISTRY_SECRET_FILE} | jq -r .auths["${REGISTRY_HOST}"].auth | base64 -d | cut -d':' -f1) \
             -p $(cat ${SECRETS_PATH}/${REGISTRY_SECRET_FILE} | jq -r .auths["${REGISTRY_HOST}"].auth | base64 -d | cut -d':' -f2) \
             ${REGISTRY_HOST}

# Build and push the multi-architecture image
docker buildx build --platform ${PLATFORMS} \
                    -t ${REGISTRY_HOST}/${REGISTRY_ORG}/${IMAGE_REPO}:${IMAGE_TAG} \
                    --push .

