#!/bin/bash

set -euo pipefail

if [[ "${1:-}" != --case ]]; then
    test_root=$(mktemp -d)
    trap 'rm -rf "${test_root}"' EXIT
    passed=0
    for credential in client token; do
        for scenario in success html-recovery transport-recovery exhaustion permanent unknown same-env switch-success switch-recovery switch-exhaustion switch-permanent missing unsafe-env initial-errexit switch-errexit inline-success inline-exhaustion inline-switch-exhaustion; do
            case_dir="${test_root}/${credential}-${scenario}"
            mkdir -p "${case_dir}/artifacts" "${case_dir}/profile"
            actual=0
            bash -x "$0" --case "${credential}" "${scenario}" "${case_dir}" > "${case_dir}/log" 2>&1 || actual=$?
            expected=0
            case "${scenario}" in initial-errexit|switch-errexit|inline-exhaustion|inline-switch-exhaustion) expected=42 ;; esac
            if [[ "${actual}" -ne "${expected}" ]]; then
                printf 'FAIL: %s/%s (expected exit %s, received %s)\n' "${credential}" "${scenario}" "${expected}" "${actual}" >&2
                exit 1
            fi
            if grep -REq 'fixture-(client|secret|token)|eyJhbGciOi|fixture-response-body|fixture-private-host|Authorization:|client_secret=' "${case_dir}/log" "${case_dir}/artifacts"; then
                printf 'FAIL: %s/%s diagnostic disclosure\n' "${credential}" "${scenario}" >&2
                exit 1
            fi
            if [[ "${scenario}" == *errexit || "${scenario}" == inline-*exhaustion ]]; then
                test "$(wc -l < "${case_dir}/calls")" -eq "$([[ "${scenario}" == *switch* ]] && echo 4 || echo 3)"
                ! grep -q continued-after-auth-failure "${case_dir}/log"
                jq -se '.[-1].exit_code == 42 and .[-1].class == "retryable_html"' "${case_dir}/artifacts/lease-health-auth.jsonl" > /dev/null
            fi
            jq -se '
                all(.[]; (.time | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
                    (.operation == "initial-login" or .operation == "environment-switch") and
                    .http_status == "unknown" and .endpoint == "unknown") and
                (group_by(.operation) | all(.[];
                    (map(select(.class == "started") | .attempt)) as $attempts |
                    $attempts == [range(1; ($attempts | length) + 1)] and ($attempts | length) <= 3))
            ' "${case_dir}/artifacts/lease-health-auth.jsonl" > /dev/null
            passed=$((passed + 1))
            printf 'PASS: %s/%s\n' "${credential}" "${scenario}"
        done
    done
    printf 'PASS: %s offline auth scenarios\n' "${passed}"
    exit 0
fi

credential="$2" scenario="$3" case_dir="$4"
export ARTIFACT_DIR="${case_dir}/artifacts" CLUSTER_PROFILE_DIR="${case_dir}/profile"
script_path="$(dirname "$0")/../ci-operator/step-registry/rosa/cluster-lease/health/rosa-cluster-lease-health-commands.sh"
source "$(dirname "$0")/../ci-operator/step-registry/rosa/cluster-lease/health/rosa-cluster-lease-health-commands.sh"
test ! -e "${ARTIFACT_DIR}/lease-health-auth.jsonl"

printf '%s' fixture-client > "${CLUSTER_PROFILE_DIR}/sso-client-id"
printf '%s' fixture-secret > "${CLUSTER_PROFILE_DIR}/sso-client-secret"
printf '%s' fixture-token > "${CLUSTER_PROFILE_DIR}/ocm-token"
if [[ "${credential}" == token ]]; then
    rm "${CLUSTER_PROFILE_DIR}/sso-client-secret"
fi
if [[ "${scenario}" == missing ]]; then
    rm -f "${CLUSTER_PROFILE_DIR}"/*
fi
export OCM_LOGIN_ENV=staging
initialize_reports
: > "${case_dir}/calls"
: > "${case_dir}/sleeps"

sleep() {
    printf '%s\n' "$1" >> "${case_dir}/sleeps"
}

ocm() {
    test "$1" = login || return 98
    test "$2" = --url || return 98
    if [[ "${credential}" == client ]]; then
        test "$4" = --client-id && test "$5" = fixture-client || return 98
        test "$6" = --client-secret && test "$7" = fixture-secret || return 98
        test "$#" -eq 7 || return 98
    else
        test "$4" = --token && test "$5" = fixture-token || return 98
        test "$#" -eq 5 || return 98
    fi
    test -s "${REPORT}" || return 98
    jq -se '.[-1].class == "started" and .[-1].exit_code == null' "${AUTH_REPORT}" > /dev/null || return 98
    printf '%s\n' "$3" >> "${case_dir}/calls"
    local count failure
    count=$(wc -l < "${case_dir}/calls")
    printf '%s\n' 'fixture-client fixture-secret fixture-token eyJhbGciOi.fixture.signature' >&2
    printf '%s\n' 'Authorization: Bearer eyJhbGciOi.fixture.signature client_secret=fixture-secret fixture-response-body'
    if [[ "$3" == staging && "${scenario}" == *switch-* ]]; then
        return 0
    fi
    failure="${scenario#inline-}"
    failure="${failure#switch-}"
    case "${failure}" in
        success|same-env) return 0 ;;
        html-recovery|recovery) [[ "${count}" -ge "$([[ "${scenario}" == switch-* ]] && echo 3 || echo 2)" ]] && return 0 ;;
        transport-recovery)
            [[ "${count}" -ge 2 ]] && return 0
            echo "Error: Can't get token: dial tcp: i/o timeout" >&2
            return 42 ;;
        permanent)
            echo 'invalid_grant: invalid refresh token; unexpected EOF' >&2
            return 43 ;;
        unknown) echo 'unrecognized login error' >&2; return 44 ;;
    esac
    echo "Error: Can't get token: expected response content type 'application/json' but received 'text/html' and content 'fixture-response-body'" >&2
    return 42
}

if [[ "${scenario}" == inline-* ]]; then
    oc() {
        [[ "$*" == *'get configmap'* ]] || return 97
        if [[ "${scenario}" == inline-switch-exhaustion ]]; then
            printf '%s\n' '{"items":[{"metadata":{"name":"fixture-cluster","labels":{"rosa-cluster-lease/status":"available"}},"data":{"cluster-id":"fixture-id","ocm-env":"production"}}]}'
        else
            printf '%s\n' '{"items":[]}'
        fi
    }
    export -f ocm oc sleep
    export credential scenario case_dir
    script=$(< "${script_path}")
    fixture_script="${script/LEASE_HOST_KUBECONFIG=\"\/etc\/rosa-cluster-lease-manager\/kubeconfig\"/LEASE_HOST_KUBECONFIG=\"${case_dir}\/lease-kubeconfig\"}"
    test "${fixture_script}" != "${script}"
    touch "${case_dir}/lease-kubeconfig"
    rm "${REPORT}" "${AUTH_REPORT}"
    actual=0
    bash -c "${fixture_script}"$'\necho continued-after-auth-failure' || actual=$?
    if [[ "${scenario}" == inline-success ]]; then
        test "${actual}" -eq 0
        grep -q 'Summary: 0 healthy, 0 unhealthy, 0 recovered' "${REPORT}"
    fi
    exit "${actual}"
fi

if [[ "${scenario}" == initial-errexit ]]; then
    ocm_authenticate
    echo continued-after-auth-failure
    exit 99
fi

actual=0
ocm_authenticate || actual=$?
case "${scenario}" in
    missing) test "${actual}" -eq 1; expected_calls=0; expected_class=missing_credentials ;;
    exhaustion) test "${actual}" -eq 42; expected_calls=3; expected_class=retryable_html ;;
    permanent) test "${actual}" -eq 43; expected_calls=1; expected_class=permanent_auth ;;
    unknown) test "${actual}" -eq 44; expected_calls=1; expected_class=unclassified ;;
    html-recovery|transport-recovery) test "${actual}" -eq 0; expected_calls=2; expected_class=success ;;
    unsafe-env) test "${actual}" -eq 42; expected_calls=3; expected_class=retryable_html ;;
    *) test "${actual}" -eq 0; expected_calls=1; expected_class=success ;;
esac

if [[ "${scenario}" == switch-* || "${scenario}" == same-env ]]; then
    if [[ "${scenario}" == switch-errexit ]]; then
        ocm_ensure_env production
        echo continued-after-auth-failure
        exit 99
    fi
    actual=0
    target_env=production
    [[ "${scenario}" == same-env ]] && target_env=staging
    ocm_ensure_env "${target_env}" || actual=$?
    case "${scenario}" in
        switch-exhaustion) test "${actual}" -eq 42; test "${CURRENT_OCM_ENV}" = staging; expected_calls=4; expected_class=retryable_html ;;
        switch-permanent) test "${actual}" -eq 43; test "${CURRENT_OCM_ENV}" = staging; expected_calls=2; expected_class=permanent_auth ;;
        switch-recovery) test "${actual}" -eq 0; test "${CURRENT_OCM_ENV}" = production; expected_calls=3 ;;
        *) test "${actual}" -eq 0; test "${CURRENT_OCM_ENV}" = "${target_env}"; expected_calls=$([[ "${scenario}" == same-env ]] && echo 1 || echo 2) ;;
    esac
fi

if [[ "${scenario}" == unsafe-env ]]; then
    actual=0
    ocm_ensure_env 'https://fixture-token@fixture-private-host/"injected' || actual=$?
    test "${actual}" -eq 42
    expected_calls=6
    jq -se '.[-1].environment == "other"' "${AUTH_REPORT}" > /dev/null
fi

test "$(wc -l < "${case_dir}/calls")" -eq "${expected_calls}"
jq -se --arg class "${expected_class}" '.[-1].class == $class and all(.[]; .http_status == "unknown" and .endpoint == "unknown" and .max_attempts == 3)' "${AUTH_REPORT}" > /dev/null
case "${scenario}" in
    html-recovery|switch-recovery) jq -se 'any(.[]; .class == "retryable_html" and .exit_code == 42)' "${AUTH_REPORT}" > /dev/null ;;
    transport-recovery) jq -se 'any(.[]; .class == "retryable_transport" and .exit_code == 42)' "${AUTH_REPORT}" > /dev/null ;;
esac
case "${scenario}" in
    exhaustion|switch-exhaustion) test "$(cat "${case_dir}/sleeps")" = $'10\n20' ;;
    html-recovery|transport-recovery|switch-recovery) test "$(cat "${case_dir}/sleeps")" = 10 ;;
    unsafe-env) test "$(cat "${case_dir}/sleeps")" = $'10\n20\n10\n20' ;;
    *) test ! -s "${case_dir}/sleeps" ;;
esac
if [[ "${actual}" -ne 0 && "${scenario}" != switch-* ]]; then
    test -z "${CURRENT_OCM_ENV}"
fi
