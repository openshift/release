#!/bin/bash
set -e

# Install Docker and related components
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update

sudo apt-get install \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin \
    -y

sudo usermod -aG docker $USER
newgrp docker

# Create and use a new Buildx builder instance
docker buildx create --use --name multiarch_builder

# Build and push multi-architecture image for ppc64le only
docker buildx build --platform linux/ppc64le \
    -t quay.io/opendatahub-io/odh-dashboard:latest \
    -f ./Dockerfile \
    --push .

