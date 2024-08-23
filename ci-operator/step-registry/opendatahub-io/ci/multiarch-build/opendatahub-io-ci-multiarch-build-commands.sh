#!/bin/bash

# Install Docker if not already installed
if ! command -v docker &> /dev/null
then
    echo "Docker not found. Installing Docker..."
    dnf install -y yum-utils \
    && dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo \
    && dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    && systemctl start docker

    if ! command -v docker &> /dev/null
    then
        echo "Docker installation failed"
        exit 1
    fi
fi

# Check if dockerd-entrypoint.sh is available
if ! command -v dockerd-entrypoint.sh &> /dev/null
then
    echo "dockerd-entrypoint.sh could not be found"
    exit 1
fi

# Start Docker daemon in the background
dockerd-entrypoint.sh &

# Wait for Docker daemon to fully start
sleep 10

# Enable Buildx for multi-platform builds
docker buildx create --use

# Log in to the registry
DOCKER_USER=$(cat "${SECRETS_PATH}/${REGISTRY_SECRET_FILE}" | jq -r ".auths[\"${REGISTRY_HOST}\"].auth" | base64 -d | cut -d':' -f1)
DOCKER_PASS=$(cat "${SECRETS_PATH}/${REGISTRY_SECRET_FILE}" | jq -r ".auths[\"${REGISTRY_HOST}\"].auth" | base64 -d | cut -d':' -f2)

docker login -u "${DOCKER_USER}" -p "${DOCKER_PASS}" "${REGISTRY_HOST}"

# Build and push the multi-architecture image
docker buildx build --platform "${PLATFORMS}" \
                    -t "${REGISTRY_HOST}/${REGISTRY_ORG}/${IMAGE_REPO}:${IMAGE_TAG}" \
                    --push

