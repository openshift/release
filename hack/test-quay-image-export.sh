#!/bin/bash
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/ci-operator/step-registry/quay/image/export/quay-image-export-commands.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT
TEST_DIGEST="sha256:$(printf '%064d' 1)"
export TEST_DIGEST

oc() {
    printf '%s\n' "$1 $2" >>"$CASE_DIR/calls"
    printf '%s\n' 'unit-test-sensitive-output' >&2
    case "$1 $2" in
        'registry login')
            if [[ "$SCENARIO" == test-cluster-kubeconfig && -v KUBECONFIG ]]; then
                printf '%s\n' 'inherited-test-cluster-kubeconfig' >"$CASE_DIR/login-misuse"
                return 11
            fi
            [[ "$SCENARIO" != login-failure ]] || return 7
            printf '%s\n' '{"auths":{"build.example":{"auth":"unit-source"},"quay.io":{"auth":"old"}}}' >"${3#--to=}"
            if [[ "$SCENARIO" == merge-failure ]]; then
                printf '{' >"${3#--to=}"
            fi
            ;;
        'image mirror')
            if [[ "$SCENARIO" == test-cluster-kubeconfig ]]; then
                [[ "${KUBECONFIG:-}" == "$CASE_DIR/test-cluster.kubeconfig" ]] || return 12
                printf '%s\n' 'preserved' >"$CASE_DIR/mirror-kubeconfig"
            fi
            local auth_file="${3#--registry-config=}"
            jq -e '.auths["build.example"].auth == "unit-source" and .auths["quay.io"].auth == "unit-destination" and (.auths | has("unrelated.example") | not)' "$auth_file" >/dev/null || return 9
            [[ "$(stat -c %a "$auth_file")" == 600 ]] || return 9
            [[ "$(stat -c %a "$(dirname "$auth_file")")" == 700 ]] || return 9
            [[ "$4" == --keep-manifest-list && "$5" == "$QUAY_EXPORT_SOURCE" && "$6" == "$QUAY_EXPORT_DESTINATION" ]] || return 9
            [[ "$SCENARIO" != mirror-failure ]] || return 8
            if [[ "$SCENARIO" == interrupted ]]; then
                kill -INT "$BASHPID"
                return 130
            elif [[ "$SCENARIO" == terminated ]]; then
                kill -TERM "$BASHPID"
                return 143
            fi
            ;;
        'image info')
            if [[ "$SCENARIO" == test-cluster-kubeconfig ]]; then
                [[ "${KUBECONFIG:-}" == "$CASE_DIR/test-cluster.kubeconfig" ]] || return 12
                printf '%s\n' 'preserved' >"$CASE_DIR/info-kubeconfig"
            fi
            [[ "$SCENARIO" != info-failure ]] || return 8
            case "$SCENARIO" in
                invalid-digest) printf '%s\n' '{"digest":"invalid"}' ;;
                missing-digest) printf '%s\n' '{}' ;;
                multiarch) printf '[{"digest":"child","listDigest":"%s"},{"digest":"other","listDigest":"%s"}]\n' "$TEST_DIGEST" "$TEST_DIGEST" ;;
                *) printf '{"digest":"%s","listDigest":""}\n' "$TEST_DIGEST" ;;
            esac
            ;;
        *) return 10 ;;
    esac
}
export -f oc

run_case() {
    local scenario="$1" expected_status="$2" expected_calls="$3" status=0
    export SCENARIO="$scenario" CASE_DIR="$test_dir/$scenario"
    mkdir -p "$CASE_DIR/tmp" "$CASE_DIR/artifacts"
    export TMPDIR="$CASE_DIR/tmp" ARTIFACT_DIR="$CASE_DIR/artifacts"
    export QUAY_EXPORT_SOURCE=build.example/ci/image:tag
    export QUAY_EXPORT_DESTINATION=quay.io/example/image:unit-test
    export QUAY_EXPORT_AUTH_FILE="$CASE_DIR/config.json"
    printf '%s\n' '{"auths":{"quay.io":{"auth":"unit-destination"},"unrelated.example":{"auth":"unit-unrelated"}}}' >"$QUAY_EXPORT_AUTH_FILE"
    : >"$CASE_DIR/calls"
    case "$scenario" in
        missing-source) unset QUAY_EXPORT_SOURCE ;;
        missing-destination) unset QUAY_EXPORT_DESTINATION ;;
        missing-auth-variable) unset QUAY_EXPORT_AUTH_FILE ;;
        missing-artifacts) unset ARTIFACT_DIR ;;
        missing-auth) rm "$QUAY_EXPORT_AUTH_FILE" ;;
        invalid-auth) printf '{' >"$QUAY_EXPORT_AUTH_FILE" ;;
        wrong-auth-host) printf '%s\n' '{"auths":{}}' >"$QUAY_EXPORT_AUTH_FILE" ;;
        unsafe-source) export QUAY_EXPORT_SOURCE='https://user:password@build.example/image:tag' ;;
        destination-option) export QUAY_EXPORT_DESTINATION='--insecure' ;;
        destination-host) export QUAY_EXPORT_DESTINATION='other.example/org/image:tag' ;;
        destination-credentials) export QUAY_EXPORT_DESTINATION='quay.io/user:password@org/image:tag' ;;
        destination-digest) export QUAY_EXPORT_DESTINATION="quay.io/org/image@$TEST_DIGEST" ;;
        digest-source) export QUAY_EXPORT_SOURCE="build.example/ci/image@$TEST_DIGEST" ;;
        test-cluster-kubeconfig) export KUBECONFIG="$CASE_DIR/test-cluster.kubeconfig" ;;
    esac
    if [[ "$scenario" == inherited-tracing ]]; then
        bash -x "$script" >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr" || status=$?
    else
        bash "$script" >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr" || status=$?
    fi
    [[ "$status" == "$expected_status" ]] || { printf 'FAIL %s: status %s\n' "$scenario" "$status"; return 1; }
    [[ "$(wc -l <"$CASE_DIR/calls")" == "$expected_calls" ]]
    [[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]]
    if [[ "$scenario" == test-cluster-kubeconfig ]]; then
        [[ "$KUBECONFIG" == "$CASE_DIR/test-cluster.kubeconfig" ]]
        [[ ! -e "$CASE_DIR/login-misuse" ]]
        grep -Fxq preserved "$CASE_DIR/mirror-kubeconfig"
        grep -Fxq preserved "$CASE_DIR/info-kubeconfig"
    fi
    if grep -Eq 'unit-test-sensitive-output|unit-source|unit-destination|unit-unrelated|password' "$CASE_DIR/stdout" "$CASE_DIR/stderr"; then
        printf 'FAIL %s: sensitive output\n' "$scenario"
        return 1
    fi
    if [[ "$expected_status" == 0 ]]; then
        jq -e --arg digest "$TEST_DIGEST" '.destination == "quay.io/example/image:unit-test" and .digest == $digest and .pullspec == ("quay.io/example/image@" + $digest)' "$ARTIFACT_DIR/quay-image-export.json" >/dev/null
    else
        [[ ! -e "$CASE_DIR/artifacts/quay-image-export.json" ]]
    fi
    printf 'PASS: %s\n' "$scenario"
}

run_case success 0 3
run_case digest-source 0 3
run_case multiarch 0 3
run_case inherited-tracing 0 3
for scenario in missing-source missing-destination missing-auth-variable missing-artifacts missing-auth invalid-auth wrong-auth-host unsafe-source destination-option destination-host destination-credentials destination-digest; do
    run_case "$scenario" 1 0
done
run_case login-failure 1 1
run_case merge-failure 1 1
run_case mirror-failure 1 2
run_case info-failure 1 3
run_case invalid-digest 1 3
run_case missing-digest 1 3
run_case terminated 143 2
run_case interrupted 130 2
run_case test-cluster-kubeconfig 0 3
