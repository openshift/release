#!/bin/bash
set -euo pipefail

script="${1:-$(dirname "$0")/../ci-operator/step-registry/mirror-images/by-oc-mirror/mirror-images-by-oc-mirror-commands.sh}"
script="$(realpath "$script")"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

check_auth() {
    jq -e '.auths["profile.example"].auth == "fake-profile-auth" and
        .auths["quay.io"].auth == "fake-upstream-auth" and
        .auths["mirror.example:5000"].auth == "ZmFrZS1taXJyb3I6ZmFrZS1wYXNzd29yZA==" and
        .auths["buildfarm.example"].auth == "fake-buildfarm-auth"' "$1" >/dev/null
}

head() {
    if [[ "${*: -1}" == /var/run/vault/mirror-registry/registry_creds ]]; then
        printf '%s\n' 'fake-mirror:fake-password'
    else
        command head "$@"
    fi
}

oc() {
    case "$1 $2" in
    'registry login')
        printf 'login\n' >>"$case_dir/events"
        [[ "${KUBECONFIG:-}" == '' ]] || return 21
        [[ "$scenario" != login-failure ]] || return 22
        local auth_file="$HOME/default-auth.json"
        if [[ "${3:-}" == --to ]]; then
            auth_file="$4"
        fi
        if [[ ! -s "$auth_file" ]]; then
            printf '{"auths":{}}\n' >"$auth_file"
        fi
        local updated
        updated="$(jq '.auths["buildfarm.example"] = {"auth":"fake-buildfarm-auth"}' "$auth_file")"
        printf '%s\n' "$updated" >"$auth_file"
        ;;
    'adm release')
        printf 'release\n' >>"$case_dir/events"
        [[ "$3" == info && "$4" == --registry-config ]] || return 23
        check_auth "$5" || return 24
        [[ "$6" == "$expected_release" ]] || return 25
        printf '4.18.0\n'
        ;;
    'get is')
        printf 'sha256:fake original.example/release@sha256:fake\n'
        ;;
    'version --client') printf 'Client Version: 4.18.0\n' ;;
    'version -o') printf '{"clientVersion":{"gitVersion":"4.18.0"}}\n' ;;
    *) return 26 ;;
    esac
}

curl() {
    local destination=''
    while (($#)); do
        if [[ "$1" == -o ]]; then
            destination="$2"
            shift
        fi
        shift
    done
    case "$destination" in
    oc-mirror.tar.gz) cp "$test_dir/oc-mirror.tar.gz" "$destination" ;;
    sha256sum.txt) cp "$test_dir/sha256sum.txt" "$destination" ;;
    *) return 27 ;;
    esac
}

export -f check_auth head oc curl
export test_dir
mkdir -p "$test_dir/archive"
cat >"$test_dir/archive/oc-mirror" <<'MOCK'
#!/bin/bash
set -euo pipefail
if [[ "$1" == version ]]; then
    printf 'version: fake\n'
    exit 0
fi
check_auth "${XDG_RUNTIME_DIR}/containers/auth.json"
check_auth "$PWD/new_pull_secret"
printf 'mirror\n' >>"$case_dir/events"
mkdir -p working-dir/cluster-resources
printf 'kind: ImageDigestMirrorSet\n' >working-dir/cluster-resources/idms-oc-mirror.yaml
MOCK
tar -czf "$test_dir/oc-mirror.tar.gz" -C "$test_dir/archive" oc-mirror
digest="$(sha256sum "$test_dir/oc-mirror.tar.gz")"
printf '%s  oc-mirror-rhel9-linux-%s.tar.gz\n' "${digest%% *}" \
    "$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')" >"$test_dir/sha256sum.txt"

run_case() {
    export scenario="$1" case_dir="$test_dir/$1"
    mkdir -p "$case_dir"/{shared,profile,home,tmp}
    export SHARED_DIR="$case_dir/shared" CLUSTER_PROFILE_DIR="$case_dir/profile"
    export HOME="$case_dir/home" TMPDIR="$case_dir/tmp"
    export KUBECONFIG="$case_dir/cluster-under-test"
    export MIRROR_BIN=oc-mirror
    export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=buildfarm.example/release@sha256:fake
    export CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=''
    export USE_ORIGINAL_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=false
    export expected_release="$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE"
    printf 'mirror.example:5000\n' >"$SHARED_DIR/mirror_registry_url"
    printf '{"auths":{"profile.example":{"auth":"fake-profile-auth"},"quay.io":{"auth":"fake-upstream-auth"}}}\n' >"$CLUSTER_PROFILE_DIR/pull-secret"
    : >"$case_dir/events"
    case "$scenario" in
    custom-release)
        export CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=quay.io/release:custom
        export expected_release="$CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE"
        ;;
    original-release)
        export USE_ORIGINAL_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=true
        export expected_release=original.example/release@sha256:fake
        ;;
    legacy-skip) export MIRROR_BIN=oc ;;
    esac
    local result=0
    bash "$script" >"$case_dir/output" 2>&1 || result=$?
    if grep -Eq 'fake-(profile|upstream|buildfarm)-auth|fake-mirror:fake-password|ZmFrZS1taXJyb3I6ZmFrZS1wYXNzd29yZA==' "$case_dir/output"; then
        printf 'FAIL: %s: credentials logged\n' "$scenario" >&2
        return 1
    fi
    case "$scenario" in
    login-failure)
        [[ "$result" == 22 && "$(cat "$case_dir/events")" == login ]]
        [[ "$(cat "$SHARED_DIR/install-pre-config-status.txt")" == 100 ]]
        ;;
    legacy-skip)
        [[ "$result" == 0 && ! -s "$case_dir/events" ]]
        ;;
    *)
        if [[ "$result" != 0 ]]; then
            printf 'FAIL: %s: script exited %s (release requires combined auth)\n' "$scenario" "$result" >&2
            return 1
        fi
        [[ "$(cat "$case_dir/events")" == $'login\nrelease\nmirror' ]]
        [[ -s "$SHARED_DIR/idms-oc-mirror.yaml" ]]
        [[ "$(cat "$SHARED_DIR/install-pre-config-status.txt")" == 0 ]]
        check_auth "$HOME/run/containers/auth.json"
        cmp -s "$CLUSTER_PROFILE_DIR/pull-secret" <(printf '{"auths":{"profile.example":{"auth":"fake-profile-auth"},"quay.io":{"auth":"fake-upstream-auth"}}}\n')
        ;;
    esac
    printf 'PASS: %s\n' "$scenario"
}

run_case perjob-release
run_case custom-release
run_case original-release
run_case login-failure
run_case legacy-skip
