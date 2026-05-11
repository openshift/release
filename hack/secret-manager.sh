#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GCLOUD_CONFIG_PATH="$SCRIPT_DIR/gcp-secret-manager/.secret-manager-gcloud"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-podman}"
IMAGE="${SECRET_MANAGER_IMAGE:-quay.io/openshift/ci-public:ci_secret-manager_latest}"

if [ "${1:-}" = "clean" ]; then
    echo "Removing cached credentials..."
    rm -rf "$GCLOUD_CONFIG_PATH"
    echo "Done. Run the 'login' command to re-authenticate."
    exit 0
fi

mkdir -p "$GCLOUD_CONFIG_PATH"

if [ "${1:-}" = "login" ]; then
    if ! command -v gcloud &>/dev/null; then
        echo "Error: 'gcloud' is not installed. Install it with: brew install google-cloud-sdk" >&2
        exit 1
    fi
    CLOUDSDK_CONFIG="$GCLOUD_CONFIG_PATH" exec gcloud auth application-default login --verbosity=error
fi

tty_flags=()
if [ -t 0 ] && [ -t 1 ]; then
    tty_flags=(-it)
fi

if ! "$CONTAINER_ENGINE" image exists "$IMAGE" 2>/dev/null; then
    "$CONTAINER_ENGINE" pull "$IMAGE" >/dev/null
fi
exec "$CONTAINER_ENGINE" run --rm "${tty_flags[@]}" \
    -v "$GCLOUD_CONFIG_PATH:/gcloud:z" \
    -e CLOUDSDK_CONFIG=/gcloud \
    -e GOOGLE_CLOUD_QUOTA_PROJECT=openshift-ci-secrets \
    "$IMAGE" "$@"
