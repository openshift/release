#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
script_dir="${WINDOWS_MIRROR_SCRIPT_DIR:-${repo_root}/ci-operator/step-registry/windows/e2e/operator/test}"
mode="${WINDOWS_MIRROR_TEST_MODE:-all}"
test_dir=$(mktemp -d)
manifests=(/tmp/image-digest-mirror-set.yaml /tmp/image-tag-mirror-set.yaml /tmp/mirror-images-list.yaml)
if [[ "$mode" != extension ]]; then
    for manifest in "${manifests[@]}"; do
        if [[ -e "$manifest" || -L "$manifest" ]]; then
            rmdir "$test_dir"
            printf 'Refusing to overwrite existing test output: %s\n' "$manifest" >&2
            exit 1
        fi
    done
fi
cleanup() {
    rm -rf "$test_dir"
    if [[ "$mode" != extension ]]; then rm -f "${manifests[@]}"; fi
}
trap cleanup EXIT

run_case() {
    local kind="$1" scenario="$2" source_image="$3" expected_status="$4" status=0
    local case_dir="$test_dir/$kind-$scenario" calls_count
    mkdir -p "$case_dir/tmp"
    printf '%s\n' registry.example:5000 >"$case_dir/mirror_registry_url"
    printf '%s\n' fixture:password >"$case_dir/registry_creds"
    printf '%s\n' '{"auths":{"source.example":{"auth":"fake-source-auth"},"quay.io":{"auth":"fake-upstream-auth"}}}' >"$case_dir/pull-secret"
    if [[ "$kind" == extension ]]; then printf 'stale-image\n' >"$case_dir/mirrored_extension_image"; fi
    : >"$case_dir/events"
    (
        export case_dir kind scenario source_image
        export SHARED_DIR="$case_dir" CLUSTER_PROFILE_DIR="$case_dir" TMPDIR="$case_dir/tmp"
        export KUBECONFIG="$case_dir/cluster-under-test" NAMESPACE=ci-fixture PAUSE_IMAGE_ORG=''
        unset EXTENSION_IMAGE
        if [[ "$kind" == extension ]]; then export EXTENSION_IMAGE="$source_image"; fi
        if [[ "$scenario" == pause-org ]]; then export PAUSE_IMAGE_ORG=fixture-org; fi
        head() {
            if [[ "${*: -1}" == /var/run/vault/mirror-registry/registry_creds ]]; then
                command head -n 1 "$case_dir/registry_creds"
            else
                command head "$@"
            fi
        }
        jq() {
            local arguments=() argument
            for argument in "$@"; do
                if [[ "$argument" == /var/run/vault/mirror-registry/registry_creds ]]; then argument="$case_dir/registry_creds"; fi
                arguments+=("$argument")
            done
            command jq "${arguments[@]}"
        }
        oc() {
            local previous='' argument auth_file='' mirror_auth=Zml4dHVyZTpwYXNzd29yZA==
            for argument in "$@"; do
                if [[ "$previous" == -a || "$previous" == --to ]]; then auth_file="$argument"; fi
                previous="$argument"
            done
            case "$1 ${2:-}" in
            'whoami ' | 'version -o') return 0 ;;
            'create -f')
                printf 'create\n' >>"$case_dir/events"
                return 0
                ;;
            'registry login')
                printf 'login\n' >>"$case_dir/events"
                [[ -n "$auth_file" && "${KUBECONFIG:-}" == '' ]] || return 90
                [[ "$scenario" != login-failure ]] || return 22
                command jq '.auths["registry.apps.build02.vmc.ci.openshift.org"] = {auth:"fake-ci-auth"}' "$auth_file" >"$case_dir/updated"
                cat "$case_dir/updated" >"$auth_file"
                return 0
                ;;
            esac
            printf '%s\n' "$auth_file" >"$case_dir/auth-path"
            if [[ "$kind" == common ]]; then mirror_auth=Zml4dHVyZTpwYXNzd29yZAo=; fi
            if ! command jq -e --arg mirror "$mirror_auth" '.auths["registry.example:5000"].auth == $mirror and .auths["source.example"].auth == "fake-source-auth" and .auths["quay.io"].auth == "fake-upstream-auth" and .auths["registry.apps.build02.vmc.ci.openshift.org"].auth == "fake-ci-auth"' "$auth_file" >/dev/null; then
                printf 'auth-rejected\n' >>"$case_dir/events"
                return 24
            fi
            if [[ "$kind" == extension ]]; then
                test ! -e "$case_dir/mirrored_extension_image" || return 91
                [[ $(stat -c %a "$auth_file") == 600 && $(stat -c %a "$(dirname "$auth_file")") == 700 ]] || return 92
            fi
            case "$1 $2" in
            'image mirror')
                printf 'mirror\n' >>"$case_dir/events"
                [[ "$*" == *'--keep-manifest-list=true'* && "$*" == *'--filter-by-os=.*'* ]] || return 93
                if [[ "$kind" == extension ]]; then
                    [[ "$3" == "$source_image" && "$4" == registry.example:5000/pipeline:wmco-tests-extension ]] || return 94
                elif [[ ! -f "$case_dir/first-mirror" ]]; then
                    [[ "$3" == registry.apps.build02.vmc.ci.openshift.org/ci-fixture/pipeline && "$4" == registry.example:5000/pipeline ]] || return 95
                    touch "$case_dir/first-mirror"
                fi
                if [[ "$scenario" == source-auth-failure || "$scenario" == destination-failure ]]; then
                    printf '%s\n' "$scenario" >>"$case_dir/events"
                    return 1
                fi
                ;;
            'image info')
                printf 'verify\n' >>"$case_dir/events"
                [[ "$3" == registry.example:5000/pipeline:wmco-tests-extension ]] || return 96
                [[ "$scenario" != verification-failure ]] || return 1
                ;;
            *) return 97 ;;
            esac
        }
        sleep() { printf 'retry\n' >>"$case_dir/events"; }
        export -f oc sleep jq head
        bash "$script_dir/mirror-${kind/common/images}/windows-e2e-operator-test-mirror-${kind/common/images}-commands.sh"
    ) >"$case_dir/output" 2>&1 || status=$?
    if [[ "$status" != "$expected_status" ]]; then
        printf 'FAIL: %s %s: expected %s got %s\n' "$kind" "$scenario" "$expected_status" "$status" >&2
        printf 'Observed fixture events:\n' >&2
        cat "$case_dir/events" >&2
        return 1
    fi
    if grep -Eq 'fake-(source|upstream|ci)-auth|fixture:password|Zml4dHVyZTpwYXNzd29yZA' "$case_dir/output"; then
        printf 'FAIL: fixture credentials logged\n' >&2
        return 1
    fi
    [[ $(head -n 1 "$case_dir/events") == login ]]
    [[ $(grep -c '^login$' "$case_dir/events") == 1 ]]
    if [[ "$scenario" == login-failure ]]; then
        [[ $(wc -l <"$case_dir/events") == 1 ]]
    elif [[ "$scenario" == source-auth-failure || "$scenario" == destination-failure ]]; then
        [[ $(grep -c '^mirror$' "$case_dir/events") == 6 && $(grep -c '^retry$' "$case_dir/events") == 5 ]]
        ! grep -q '^verify$\|^create$' "$case_dir/events"
    fi
    if [[ "$kind" == extension ]]; then
        [[ -z $(ls -A "$case_dir/tmp") ]]
        if [[ -f "$case_dir/auth-path" ]]; then test ! -e "$(cat "$case_dir/auth-path")"; fi
        if [[ "$expected_status" == 0 ]]; then
            [[ $(cat "$case_dir/events") == $'login\nmirror\nverify' ]]
            [[ $(cat "$case_dir/mirrored_extension_image") == registry.example:5000/pipeline:wmco-tests-extension ]]
            [[ -f "$case_dir/openshift-tests-registry-auth" ]]
            [[ $(stat -c %a "$case_dir/openshift-tests-registry-auth") == 600 ]]
            [[ $(cat "$case_dir/cluster-debug-tools.env") == "export REGISTRY_AUTH_FILE=\"$case_dir/openshift-tests-registry-auth\"" ]]
        else
            test ! -e "$case_dir/mirrored_extension_image"
        fi
    else
        test ! -e "$case_dir/mirrored_extension_image"
        if [[ "$expected_status" == 0 ]]; then
            test ! -e "$case_dir/new_pull_secret"
            calls_count=$(grep -c '^mirror$' "$case_dir/events")
            [[ "$calls_count" == 18 && $(grep -c '^create$' "$case_dir/events") == 2 ]]
            grep -q 'registry.access.redhat.com/ubi9/ubi:latest' /tmp/mirror-images-list.yaml
            if [[ "$scenario" == pause-org ]]; then grep -q 'fixture-org/oss/kubernetes/pause:3.9' /tmp/mirror-images-list.yaml; fi
        fi
    fi
    printf 'PASS: %s %s\n' "$kind" "$scenario"
}

if [[ "$mode" != extension ]]; then
    run_case common legacy-success '' 0
    run_case common pause-org '' 0
    run_case common login-failure '' 22
    run_case common source-auth-failure '' 1
    run_case common destination-failure '' 1
fi
if [[ "$mode" != common ]]; then
    run_case extension fbc-tag registry.apps.build02.vmc.ci.openshift.org/ci-fixture/pipeline:wmco-tests 0
    run_case extension ote-tag registry.apps.build02.vmc.ci.openshift.org/ci-fixture/pipeline:windows-machine-config-operator-test 0
    run_case extension fbc-digest "registry.apps.build02.vmc.ci.openshift.org/ci-fixture/pipeline@sha256:$(printf 'a%.0s' {1..64})" 0
    run_case extension ote-digest "registry.apps.build02.vmc.ci.openshift.org/ci-fixture/pipeline@sha256:$(printf 'b%.0s' {1..64})" 0
    run_case extension login-failure registry.apps.build02.vmc.ci.openshift.org/ci-fixture/pipeline:wmco-tests 22
    run_case extension source-auth-failure registry.apps.build02.vmc.ci.openshift.org/ci-fixture/pipeline:wmco-tests 1
    run_case extension destination-failure registry.apps.build02.vmc.ci.openshift.org/ci-fixture/pipeline:wmco-tests 1
    run_case extension verification-failure registry.apps.build02.vmc.ci.openshift.org/ci-fixture/pipeline:wmco-tests 1
fi
