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
    CLOUDSDK_CONFIG="$GCLOUD_CONFIG_PATH" gcloud auth application-default login --verbosity=error
    chmod -R a+rX "$GCLOUD_CONFIG_PATH"
    exit 0
fi

tty_flags=()
if [ -t 0 ] && [ -t 1 ]; then
    tty_flags=(-it)
fi

resolve_path() {
    if [[ "$1" = /* ]]; then
        echo "$1"
    else
        echo "$(pwd)/$1"
    fi
}

args=()
file_mount=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--from-file)
            if [[ -n "${2:-}" ]]; then
                host_path="$(resolve_path "$2")"
                if [[ -f "$host_path" ]]; then
                    container_path="/input/$(basename "$host_path")"
                    file_mount=(-v "$host_path:$container_path:ro,z")
                    args+=("$1" "$container_path")
                else
                    args+=("$1" "$2")
                fi
                shift 2
            else
                args+=("$1")
                shift
            fi
            ;;
        --from-file=*)
            file_arg="${1#--from-file=}"
            host_path="$(resolve_path "$file_arg")"
            if [[ -f "$host_path" ]]; then
                container_path="/input/$(basename "$host_path")"
                file_mount=(-v "$host_path:$container_path:ro,z")
                args+=("--from-file=$container_path")
            else
                args+=("$1")
            fi
            shift
            ;;
        *)
            args+=("$1")
            shift
            ;;
    esac
done

if ! "$CONTAINER_ENGINE" image exists "$IMAGE" 2>/dev/null; then
    "$CONTAINER_ENGINE" pull "$IMAGE" >/dev/null
fi
exec "$CONTAINER_ENGINE" run --rm "${tty_flags[@]}" \
    -v "$GCLOUD_CONFIG_PATH:/gcloud:z" \
    ${file_mount[@]+"${file_mount[@]}"} \
    -e CLOUDSDK_CONFIG=/gcloud \
    -e GOOGLE_CLOUD_QUOTA_PROJECT=openshift-ci-secrets \
    "$IMAGE" "${args[@]}"
