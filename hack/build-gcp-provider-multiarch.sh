#!/bin/bash

# Builds a multi-arch manifest list for the GCP Secrets Store CSI Driver Provider.
#
# Google's published image only includes amd64 and arm64. This script builds
# the missing s390x and ppc64le architectures from source and combines all four
# into a single manifest list.
#
# Usage:
#   ./hack/build-gcp-provider-multiarch.sh [VERSION]
#
# VERSION defaults to the latest GitHub release tag.
# Pushes to quay.io/openshift/ci-public.

set -o errexit
set -o nounset
set -o pipefail

UPSTREAM_REPO="GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp"
UPSTREAM_IMAGE="us-docker.pkg.dev/secretmanager-csi/secrets-store-csi-driver-provider-gcp/plugin"
EXTRA_PLATFORMS=("linux/s390x" "linux/ppc64le")

CONTAINER_ENGINE=${CONTAINER_ENGINE:-podman}
if [[ "${CONTAINER_ENGINE}" != "podman" ]]; then
    echo "This script requires podman" >&2
    exit 1
fi

resolve_latest_version() {
    local version
    if command -v gh &>/dev/null; then
        version=$(gh api "repos/${UPSTREAM_REPO}/releases/latest" --jq '.tag_name')
    else
        version=$(curl -sS "https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest" | grep '"tag_name"' | cut -d'"' -f4)
    fi
    if [[ -z "${version}" ]]; then
        echo "Failed to resolve latest version" >&2
        exit 1
    fi
    echo "${version}"
}

VERSION="${1:-$(resolve_latest_version)}"
IMAGE_TAG="ci_secrets-store-csi-driver-provider-gcp_${VERSION}"
TARGET="quay.io/openshift/ci-public:${IMAGE_TAG}"

echo "Version:       ${VERSION}"
echo "Source image:   ${UPSTREAM_IMAGE}:${VERSION}"
echo "Target image:   ${TARGET}"
echo

WORKDIR=$(mktemp -d)
trap 'rm -rf "${WORKDIR}"' EXIT

echo "Cloning ${UPSTREAM_REPO} at ${VERSION}..."
git clone --depth 1 --branch "${VERSION}" \
    "https://github.com/${UPSTREAM_REPO}.git" "${WORKDIR}/src" --quiet

echo "Building extra architectures..."
for platform in "${EXTRA_PLATFORMS[@]}"; do
    arch="${platform#linux/}"
    tag="localhost/gcp-provider:${VERSION}-${arch}"
    echo "  Building ${platform}..."
    ${CONTAINER_ENGINE} build \
        --platform "${platform}" \
        --build-arg "TARGETARCH=${arch}" \
        --build-arg "VERSION=${VERSION}" \
        -t "${tag}" \
        "${WORKDIR}/src"
done

echo "Creating manifest list..."
${CONTAINER_ENGINE} manifest create "${TARGET}"

echo "Adding upstream amd64 and arm64 images..."
upstream_manifests=$(${CONTAINER_ENGINE} manifest inspect "${UPSTREAM_IMAGE}:${VERSION}")
for arch in amd64 arm64; do
    digest=$(echo "${upstream_manifests}" | \
        jq -r --arg arch "${arch}" '.manifests[] | select(.platform.architecture == $arch and .platform.os == "linux") | .digest')
    if [[ -z "${digest}" ]]; then
        echo "  Failed to find ${arch} digest in upstream image" >&2
        exit 1
    fi
    echo "  Adding ${arch}: ${digest}"
    ${CONTAINER_ENGINE} manifest add "${TARGET}" \
        "docker://${UPSTREAM_IMAGE}@${digest}"
done

echo "Adding locally built images..."
for platform in "${EXTRA_PLATFORMS[@]}"; do
    arch="${platform#linux/}"
    tag="localhost/gcp-provider:${VERSION}-${arch}"
    echo "  Adding ${arch}..."
    ${CONTAINER_ENGINE} manifest add "${TARGET}" \
        "containers-storage:${tag}"
done

echo
echo "Manifest list contents:"
${CONTAINER_ENGINE} manifest inspect "${TARGET}" | \
    jq -r '.manifests[] | select(.platform.os != null) | "  \(.platform.os)/\(.platform.architecture): \(.digest[:20])..."'

echo
echo "Pushing to quay.io/openshift/ci-public..."
${CONTAINER_ENGINE} manifest push "${TARGET}"

echo
echo "Done. Image pushed to:"
echo "  ${TARGET}"
echo "To update provider-gcp-plugin.yaml, use the manifest list digest from the push output."