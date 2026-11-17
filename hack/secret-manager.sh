#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GCLOUD_CONFIG_PATH="$SCRIPT_DIR/gcp-secret-manager/.secret-manager-gcloud"
SSO_AUTH_CONFIG_PATH="$SCRIPT_DIR/gcp-secret-manager/.secret-manager-dex"
IMAGE_CHECK_STAMP="$SCRIPT_DIR/gcp-secret-manager/.secret-manager-image-check"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-podman}"
IMAGE="${SECRET_MANAGER_IMAGE:-quay.io/openshift/ci-public:ci_secret-manager_latest}"
HOST_OS="$(uname -s)"

# On macOS the CLI runs natively instead of in a container. The container path
# relies on virtiofs ownership emulation that podman cannot provide reliably:
# mounts appear inside the VM as root, podman pins the credential directories
# with a user.containers.override_stat xattr that later runs cannot write
# through, and the SSO callback port and browser have to be tunnelled out of the
# VM. Natively none of that applies, because the CLI binds loopback and opens
# the browser itself.
#
# There is no published package for the CLI, so pin the source to a commit and
# install its pinned requirements into a private virtualenv. When the image is
# bumped, update NATIVE_COMMIT to the ci-tools-standalone commit it was built
# from, otherwise macOS silently stays behind the container path.
NATIVE_COMMIT="4daba691a18147afa424be4aa288e5d853323cc0"
# Each commit gets its own immutable directory. A newer pin provisions a new
# directory rather than moving or deleting the one an in-flight invocation may
# already be running from, which publishing then reduces to a single rename.
# Directories for other commits are pruned once they are old enough that no
# invocation can still be using them.
NATIVE_ROOT="$SCRIPT_DIR/gcp-secret-manager/.secret-manager-native"
NATIVE_DIR="$NATIVE_ROOT/$NATIVE_COMMIT"
NATIVE_LOCK="$NATIVE_ROOT/.lock"
NATIVE_STAGE=""
NATIVE_SRC="$NATIVE_DIR/src"
NATIVE_PYTHON="$NATIVE_DIR/venv/bin/python3"
NATIVE_MAIN="$NATIVE_SRC/cmd/secret-manager/main.py"

use_native() {
    # SECRET_MANAGER_CONTAINER=1 forces the container path on macOS, for example
    # to test a locally built image via SECRET_MANAGER_IMAGE.
    [ "$HOST_OS" = Darwin ] && [ "${SECRET_MANAGER_CONTAINER:-}" != 1 ]
}

if [ "${1:-}" = "clean" ]; then
    echo "Removing cached credentials..."
    rm -rf "$GCLOUD_CONFIG_PATH" "$SSO_AUTH_CONFIG_PATH"
    echo "Done. Run the 'login' command to re-authenticate."
    if use_native && [ -d "$NATIVE_ROOT" ]; then
        echo "The native CLI cache in $NATIVE_ROOT is kept; remove it to reclaim disk space."
    fi
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

# native_cli_ready is true once a commit's directory exists and has an
# interpreter. A directory only ever appears through the rename below, so its
# presence implies a complete build.
native_cli_ready() {
    [ -x "$NATIVE_PYTHON" ]
}

# prune_native_caches removes caches for other commits that are far too old for
# a running invocation to still be using them. The current commit's directory is
# never touched, and neither is anything that is not a commit-directory name.
prune_native_caches() {
    local dir base
    for dir in "$NATIVE_ROOT"/*/; do
        [ -d "$dir" ] || continue
        base="${dir%/}"
        base="${base##*/}"
        [ "${#base}" -eq 40 ] || continue
        case "$base" in
            "$NATIVE_COMMIT" | *[!0-9a-f]*) continue ;;
        esac
        if [ -n "$(find "$dir" -maxdepth 0 -mtime +7 2>/dev/null)" ]; then
            rm -rf "$dir"
        fi
    done
}

# release_native_lock drops the lock if this process still owns it and disarms
# the EXIT trap. Ownership is checked rather than releasing by path alone: after
# publishing, this run goes on to execute the CLI (possibly an interactive
# login), and by then the lock path may have been reclaimed and re-acquired by
# another run whose lock must not be deleted from here.
release_native_lock() {
    if [ -n "$NATIVE_STAGE" ]; then
        rm -rf "$NATIVE_STAGE"
        NATIVE_STAGE=""
    fi
    if [ "$(cat "$NATIVE_LOCK/pid" 2>/dev/null || true)" = "$$" ]; then
        rm -rf "$NATIVE_LOCK"
    fi
    trap - EXIT
}

# ensure_native_cli provisions the pinned CLI source and its virtualenv. The
# build happens in a per-process staging directory that is published with a
# rename, and a lock keeps concurrent runs from downloading and installing
# twice. Neither step can destroy a cache another run is using, and a failed
# attempt leaves any previously working cache in place.
ensure_native_cli() {
    native_cli_ready && return 0
    if ! command -v uv &>/dev/null; then
        echo "Error: 'uv' is not installed. Install it with: brew install uv" >&2
        exit 1
    fi
    local waited=0 holder="" claimed="" reclaimable=""
    mkdir -p "$NATIVE_ROOT"
    NATIVE_STAGE="$NATIVE_ROOT/.stage.$$"
    while ! mkdir "$NATIVE_LOCK" 2>/dev/null; do
        native_cli_ready && return 0
        # A killed run leaves the lock behind. A lock that names a live holder is
        # never disturbed, however old it is: age alone would steal the lock from
        # a slow but healthy run and make it provision twice.
        holder="$(cat "$NATIVE_LOCK/pid" 2>/dev/null || true)"
        reclaimable=""
        if [ -n "$holder" ]; then
            kill -0 "$holder" 2>/dev/null || reclaimable=yes
        elif [ -n "$(find "$NATIVE_LOCK" -mmin +1 2>/dev/null)" ]; then
            # No PID recorded. That is only legitimate for the microseconds
            # between mkdir and writing the PID, so a lock still PID-less after a
            # minute was abandoned there and would otherwise block every later
            # run forever. Note -mmin +1, not +0: on BSD/macOS find, +0 matches
            # anything older than a second, which would reclaim a lock out from
            # under a run that is still writing its PID.
            reclaimable=yes
        fi
        if [ -n "$reclaimable" ]; then
            # Claim the lock by renaming it before inspecting, so a lock that a
            # concurrent run replaces underneath us is never deleted: we only
            # remove what we can prove is the same holder we judged abandoned.
            claimed="$NATIVE_LOCK.stale.$$"
            rm -rf "$claimed"
            if mv "$NATIVE_LOCK" "$claimed" 2>/dev/null; then
                if [ "$(cat "$claimed/pid" 2>/dev/null || true)" = "$holder" ]; then
                    rm -rf "$claimed"
                    continue
                fi
                # A different run replaced the lock; hand it back and wait.
                mv "$claimed" "$NATIVE_LOCK" 2>/dev/null || rm -rf "$claimed"
            fi
        fi
        if [ "$waited" -ge 600 ]; then
            echo "Error: timed out waiting for another run to set up the CLI; remove $NATIVE_LOCK if none is running." >&2
            exit 1
        fi
        if [ "$waited" -eq 0 ]; then
            echo "Waiting for another run to finish setting up the CLI..." >&2
        fi
        waited=$((waited + 1))
        sleep 0.5
    done
    # NATIVE_STAGE is deliberately not "local": the trap runs at exit, after this
    # function has returned and its locals are gone. Arm it before the PID write
    # so a failed write cannot leave an ownerless lock behind; if one is left
    # anyway it is reclaimed above once it has been PID-less for a minute.
    trap release_native_lock EXIT
    printf '%s' "$$" >"$NATIVE_LOCK/pid"
    # Another run may have finished provisioning while we waited for the lock.
    if native_cli_ready; then
        release_native_lock
        return 0
    fi
    echo "Setting up the native secret-manager CLI at ${NATIVE_COMMIT:0:12} (first run only)..." >&2
    mkdir -p "$NATIVE_STAGE/src"
    if ! curl -fsSL --max-time 300 \
        "https://codeload.github.com/openshift/ci-tools-standalone/tar.gz/$NATIVE_COMMIT" |
        tar -xz -C "$NATIVE_STAGE/src" --strip-components=1; then
        echo "Error: could not download ci-tools-standalone at $NATIVE_COMMIT." >&2
        exit 1
    fi
    if [ ! -f "$NATIVE_STAGE/src/cmd/secret-manager/main.py" ] ||
        [ ! -f "$NATIVE_STAGE/src/cmd/secret-manager/requirements.txt" ]; then
        echo "Error: unexpected ci-tools-standalone layout at $NATIVE_COMMIT." >&2
        exit 1
    fi
    uv venv -q -p 3.12 "$NATIVE_STAGE/venv"
    uv pip install -q --python "$NATIVE_STAGE/venv/bin/python3" \
        -r "$NATIVE_STAGE/src/cmd/secret-manager/requirements.txt"
    printf '%s' "$NATIVE_COMMIT" >"$NATIVE_STAGE/commit"
    # Publish with a single rename into this commit's own directory. Nothing is
    # moved or removed, so a concurrent invocation running from another commit's
    # directory is unaffected.
    if ! mv "$NATIVE_STAGE" "$NATIVE_DIR" 2>/dev/null && ! native_cli_ready; then
        echo "Error: could not publish the native CLI cache." >&2
        exit 1
    fi
    prune_native_caches
    release_native_lock
}

# run_native executes the CLI directly. SM_CALLBACK_HOST and SM_BROWSER_REQUEST
# are removed from the environment so the CLI uses its own defaults - listen on
# loopback, open the browser itself - even if the caller exported them. They
# must be unset rather than set to an empty string, because an empty
# SM_CALLBACK_HOST would make the CLI bind all interfaces. `env -u` scopes this
# to the command and leaves the caller's environment alone.
run_native() {
    ensure_native_cli
    mkdir -p "$SSO_AUTH_CONFIG_PATH" "$GCLOUD_CONFIG_PATH"
    # Both directories hold credentials (an ADC refresh token and an SSO token).
    # The container path needs them readable by its mapped UID; natively they are
    # only ever read by this user, so keep them private.
    chmod 700 "$SSO_AUTH_CONFIG_PATH" "$GCLOUD_CONFIG_PATH"
    env -u SM_BROWSER_REQUEST -u SM_CALLBACK_HOST \
        CLOUDSDK_CONFIG="$GCLOUD_CONFIG_PATH" \
        SM_AUTH_DIR="$SSO_AUTH_CONFIG_PATH" \
        GOOGLE_CLOUD_QUOTA_PROJECT=openshift-ci-secrets \
        "$NATIVE_PYTHON" "$NATIVE_MAIN" "$@"
}

mkdir -p "$GCLOUD_CONFIG_PATH"

if [ "${1:-}" = "login" ] && [ "$#" -eq 1 ]; then
    if ! command -v gcloud &>/dev/null; then
        echo "Error: 'gcloud' is not installed. Install it with: brew install google-cloud-sdk" >&2
        exit 1
    fi
    CLOUDSDK_CONFIG="$GCLOUD_CONFIG_PATH" gcloud auth application-default login --verbosity=error
    if ! use_native; then
        # The container runs as a mapped, unprivileged UID and needs to read the
        # credentials directory; natively the CLI runs as this user already.
        chmod -R a+rX "$GCLOUD_CONFIG_PATH"
        update_image_if_stale
        touch "$IMAGE_CHECK_STAMP"
    fi
fi

# Other commands check for a newer image at most once a day.
if ! use_native && [ "${1:-}" != "login" ] &&
    [ -z "$(find "$IMAGE_CHECK_STAMP" -mmin -1440 2>/dev/null)" ]; then
    update_image_if_stale
    touch "$IMAGE_CHECK_STAMP"
fi

if use_native; then
    run_native "$@"
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
                        opener=xdg-open
                        if [ "$HOST_OS" = Darwin ]; then
                            opener=open
                        fi
                        if ! "$opener" "$url" >/dev/null 2>&1; then
                            printf 'Could not open a browser. To log in, open this URL in a browser on this machine:\n\n    %s\n\n' "$url" >&2
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
