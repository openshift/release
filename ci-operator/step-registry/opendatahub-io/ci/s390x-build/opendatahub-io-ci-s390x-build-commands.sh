#!/bin/sh

# Ensure necessary tools are installed: make, sed (bash is not needed as we are using sh)
apk update && apk add --no-cache make sed


# Enable Buildx for s390x builds
docker buildx create --platform="${PLATFORMS}" --name mybuilder --use

# Log in to the registry
DOCKER_USER=$(cat "${SECRETS_PATH}/${REGISTRY_SECRET_FILE}" | jq -r ".auths[\"${REGISTRY_HOST}\"].auth" | base64 -d | cut -d':' -f1)
DOCKER_PASS=$(cat "${SECRETS_PATH}/${REGISTRY_SECRET_FILE}" | jq -r ".auths[\"${REGISTRY_HOST}\"].auth" | base64 -d | cut -d':' -f2)

docker login -u "${DOCKER_USER}" -p "${DOCKER_PASS}" "${REGISTRY_HOST}"

# Build and push the multi-architecture image
echo "pushing image ${IMAGE_REPO}:${IMAGE_TAG} to ${REGISTRY_HOST}/${REGISTRY_ORG} "
docker buildx build --platform "${PLATFORMS}" \
                    -t "${REGISTRY_HOST}/${REGISTRY_ORG}/${IMAGE_REPO}:${IMAGE_TAG}" \
                    --push

