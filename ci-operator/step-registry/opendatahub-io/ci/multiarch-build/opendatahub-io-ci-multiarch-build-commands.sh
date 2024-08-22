#!/bin/bash
set -e

# Create and use a new Buildx builder instance
podman buildx create --use --name multiarch_builder

# Build and push multi-architecture image for ppc64le only
podman buildx build --platform linux/ppc64le \
    -t quay.io/opendatahub-io/odh-dashboard:latest \
    -f ./Dockerfile \
    --push .

