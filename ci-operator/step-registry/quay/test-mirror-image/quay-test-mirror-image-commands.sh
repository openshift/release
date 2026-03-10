#!/bin/bash
set -euo pipefail

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
mkdir -p "${XDG_RUNTIME_DIR}/containers"

QUAY_USERNAME="${QUAY_USERNAME:-admin}"
QUAY_PASSWORD="${QUAY_PASSWORD:-}"
SOURCE_IMAGE="${SOURCE_IMAGE:-registry.access.redhat.com/ubi9/ubi-micro:latest}"
DEST_REPO="${DEST_REPO:-admin/smoke-test:latest}"

# Read password from SHARED_DIR if not set via env
if [[ -z "$QUAY_PASSWORD" && -f "${SHARED_DIR}/quay-admin-password" ]]; then
  QUAY_PASSWORD="$(cat "${SHARED_DIR}/quay-admin-password")"
fi

registryEndpoint="$(oc -n quay get quayregistry quay -o jsonpath='{.status.registryEndpoint}')"
registry="${registryEndpoint#https://}"

oc registry login --registry "$registry" --auth-basic "${QUAY_USERNAME}:${QUAY_PASSWORD}" --to="${XDG_RUNTIME_DIR}/containers/auth.json"

for attempt in $(seq 1 5); do
  echo "Image mirror attempt $attempt/5..."
  if oc image mirror --insecure=true -a "${XDG_RUNTIME_DIR}/containers/auth.json" \
    "$SOURCE_IMAGE" "$registry/$DEST_REPO" \
    --filter-by-os=linux/amd64 --keep-manifest-list=false; then
    echo "Image mirror succeeded"
    exit 0
  fi
  echo "Attempt $attempt failed, retrying in 30s..."
  sleep 30
done
echo "Image mirror failed after 5 attempts"
exit 1
