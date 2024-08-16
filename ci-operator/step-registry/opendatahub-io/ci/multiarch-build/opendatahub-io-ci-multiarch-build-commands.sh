#!/bin/bash
set -e

# Create and use a new Buildx builder instance
docker buildx create --use --name multiarch_builder

# Build and push multi-architecture image for ppc64le only
docker buildx build --platform linux/ppc64le \
    -t quay.io/opendatahub-io/odh-dashboard:latest \
    -f ./Dockerfile \
    --push .

