#!/bin/bash
set -e

# Install Docker and related components using yum
yum update -y
yum install -y \
    docker \
    containerd \
    docker-buildx-plugin

# Create and use a new Buildx builder instance
docker buildx create --use --name multiarch_builder

# Build and push multi-architecture image for ppc64le only
docker buildx build --platform linux/ppc64le \
    -t quay.io/opendatahub-io/odh-dashboard:latest \
    -f ./Dockerfile \
    --push .

