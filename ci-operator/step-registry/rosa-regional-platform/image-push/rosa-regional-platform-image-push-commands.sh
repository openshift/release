#!/bin/bash

set -euo pipefail

if [[ -z "${ROSA_REGIONAL_QUAY_DEST_REPO:-}" ]]; then
  echo "ERROR: ROSA_REGIONAL_QUAY_DEST_REPO must be set" >&2
  exit 1
fi

if [[ -z "${CI_COMPONENT_IMAGE:-}" ]]; then
  echo "ERROR: CI_COMPONENT_IMAGE is not set (check dependencies)" >&2
  exit 1
fi

AUTHFILE="/var/run/quay-push-credentials/.dockerconfigjson"
if [[ ! -r "${AUTHFILE}" ]]; then
  echo "ERROR: ${AUTHFILE} not found or not readable" >&2
  exit 1
fi

# Set up merged credentials: quay push + CI registry
export HOME=/tmp/home
export XDG_RUNTIME_DIR="${HOME}/run"
mkdir -p "$HOME/.docker" "${XDG_RUNTIME_DIR}/containers"
cp "${AUTHFILE}" "$HOME/.docker/config.json"
oc registry login

TAG="ci-${PULL_NUMBER:-0}-${BUILD_ID:-unknown}"
DEST="${ROSA_REGIONAL_QUAY_DEST_REPO}:${TAG}"

echo "Copying image to quay.io..."
echo "  Source: ${CI_COMPONENT_IMAGE}"
echo "  Destination: ${DEST}"

oc image mirror "${CI_COMPONENT_IMAGE}" "${DEST}"

if [[ -z "${PULL_NUMBER:-}" ]]; then
  LATEST="${ROSA_REGIONAL_QUAY_DEST_REPO}:latest"
  echo "Postsubmit: also tagging as ${LATEST}"
  oc image mirror "${CI_COMPONENT_IMAGE}" "${LATEST}"
fi

echo "${DEST}" > "${SHARED_DIR}/component-image-override"
echo "Image pushed successfully: ${DEST}"
