#!/bin/bash
set -e

# Create and use a new Buildx builder instance
docker buildx create --use --name multiarch_builder

# Build and push multi-architecture image
docker buildx build --platform linux/amd64,linux/arm64,linux/ppc64le,linux/s390x \
    -t quay.io/opendatahub-io/odh-dashboard:latest \
    -f ./Dockerfile \
    --push .
