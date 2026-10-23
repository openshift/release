#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GCLOUD_CONFIG_PATH="$SCRIPT_DIR/gcp-secret-manager/.secret-manager-gcloud"
SSO_AUTH_CONFIG_PATH="$SCRIPT_DIR/gcp-secret-manager/.secret-manager-dex"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-podman}"
IMAGE="${SECRET_MANAGER_IMAGE:-quay.io/openshift/ci-public:ci_secret-manager_latest}"

if [ "${1:-}" = "clean" ]; then
    echo "Removing cached credentials..."
    rm -rf "$GCLOUD_CONFIG_PATH" "$SSO_AUTH_CONFIG_PATH"
    echo "Done. Run the 'login' command to re-authenticate."
    exit 0
fi

# update_image_if_stale pulls IMAGE when its quay.io tag points to a different manifest
# than the local copy. It does nothing for other registries or when quay.io cannot be checked.
update_image_if_stale() {
    local repo="${IMAGE%:*}" tag="${IMAGE##*:}" digest local_digests
    if [[ "$repo" != quay.io/* || "$repo" = *@* || "$tag" = */* ]]; then
        return 0
    fi
    digest="$(curl -fsSI --max-time 5 \
        -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
        "https://quay.io/v2/${repo#quay.io/}/manifests/$tag" 2>/dev/null |
        tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }')" || return 0
    if [[ "$digest" != sha256:* ]]; then
        return 0
    fi
    local_digests="$("$CONTAINER_ENGINE" image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$IMAGE" 2>/dev/null || true)"
    if grep -qxF "$repo@$digest" <<<"$local_digests"; then
        return 0
    fi
    if [[ -z "$local_digests" ]]; then
        echo "The secret-manager image is missing locally, downloading $IMAGE..." >&2
    else
        echo "A newer secret-manager image is available, updating $IMAGE..." >&2
    fi
    if "$CONTAINER_ENGINE" pull "$IMAGE" >/dev/null; then
        echo "The secret-manager image is up to date." >&2
    else
        echo "Warning: failed to pull $IMAGE." >&2
    fi
}

mkdir -p "$GCLOUD_CONFIG_PATH"

if [ "${1:-}" = "login" ] && [ "$#" -eq 1 ]; then
    if ! command -v gcloud &>/dev/null; then
        echo "Error: 'gcloud' is not installed. Install it with: brew install google-cloud-sdk" >&2
        exit 1
    fi
    CLOUDSDK_CONFIG="$GCLOUD_CONFIG_PATH" gcloud auth application-default login --verbosity=error
    chmod -R a+rX "$GCLOUD_CONFIG_PATH"
    update_image_if_stale
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
auth_flags=()
browser_pid=""
browser_dir=""
cleanup() {
    if [[ -n "$browser_pid" ]]; then
        kill "$browser_pid" 2>/dev/null || true
        wait "$browser_pid" 2>/dev/null || true
    fi
    if [[ -n "$browser_dir" ]]; then
        rm -rf "$browser_dir"
    fi
}
trap cleanup EXIT

needs_sso=false
if [[ "${args[0]:-}" = "login" ]]; then
    needs_sso=true
elif [[ "${args[0]:-}" = "list" ]]; then
    for arg in ${args[@]+"${args[@]}"}; do
        case "$arg" in
            -c*|--collection|--collection=*) needs_sso=true ;;
        esac
    done
fi
if [[ "$needs_sso" = true ]]; then
    mkdir -p "$SSO_AUTH_CONFIG_PATH"
    chmod 700 "$SSO_AUTH_CONFIG_PATH"
    browser_dir="$(mktemp -d "$SSO_AUTH_CONFIG_PATH/browser.XXXXXX")"
    (
        while true; do
            if [[ -f "$browser_dir/url" ]]; then
                url="$(<"$browser_dir/url")"
                rm -f "$browser_dir/url"
                case "$url" in
                    https://idp.ci.openshift.org/auth\?*)
                        if command -v open &>/dev/null; then
                            open "$url" >/dev/null 2>&1 || true
                        elif command -v xdg-open &>/dev/null; then
                            xdg-open "$url" >/dev/null 2>&1 || true
                        fi
                        ;;
                esac
            fi
            sleep 0.2
        done
    ) &
    browser_pid=$!
    # Map the host user to the image's UID 1001 so it can write the mode-700 SSO directories.
    case "$(basename "$CONTAINER_ENGINE")" in
        docker) auth_flags=(--user "$(id -u):$(id -g)") ;;
        *) auth_flags=(--userns=keep-id:uid=1001,gid=1001) ;;
    esac
    auth_flags+=(-p 127.0.0.1:8085:8085
        -v "$SSO_AUTH_CONFIG_PATH:/auth:z"
        -v "$browser_dir:/browser:z"
        -e SM_AUTH_DIR=/auth -e SM_CALLBACK_HOST=0.0.0.0
        -e SM_BROWSER_REQUEST=/browser/url)
fi

"$CONTAINER_ENGINE" run --rm ${tty_flags[@]+"${tty_flags[@]}"} \
    ${auth_flags[@]+"${auth_flags[@]}"} \
    -v "$GCLOUD_CONFIG_PATH:/gcloud:z" \
    ${file_mount[@]+"${file_mount[@]}"} \
    -e CLOUDSDK_CONFIG=/gcloud \
    -e GOOGLE_CLOUD_QUOTA_PROJECT=openshift-ci-secrets \
    "$IMAGE" ${args[@]+"${args[@]}"}
