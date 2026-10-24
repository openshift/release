#!/bin/bash
set -euo pipefail

script_path="$(cd "$(dirname "$0")/.." && pwd)/ci-operator/step-registry/rosa/cluster-lease/controller/rosa-cluster-lease-controller-commands.sh"

if [[ "${1:-}" != --case ]]; then
    results=$(mktemp -d)
    trap 'rm -rf "${results}"' EXIT
    count=0
    for credential in client token partial partial-missing missing; do
        for scenario in success html-recovery exhaustion final-exit transport-recovery transport-tls transport-reset transport-eof transport-dns transport-deadline permanent mixed unknown near-miss same-env switch-success switch-recovery switch-exhaustion switch-permanent unsafe-env initial-errexit switch-errexit inline-success inline-exhaustion inline-switch-exhaustion inline-permanent; do
            case "${credential}:${scenario}" in
                missing:success|partial:success|partial-missing:success) ;;
                missing:*|partial:*|partial-missing:*) continue ;;
            esac
            case_dir="${results}/${credential}-${scenario}"
            mkdir -p "${case_dir}"
            actual=0
            bash -x "$0" --case "${credential}" "${scenario}" "${case_dir}" > "${case_dir}/console" 2>&1 || actual=$?
            expected=0
            case "${scenario}" in
                initial-errexit|switch-errexit|inline-exhaustion|inline-switch-exhaustion) expected=42 ;;
                inline-permanent) expected=43 ;;
            esac
            if [[ "${actual}" != "${expected}" ]]; then
                printf 'FAIL: %s/%s: exit %s, expected %s\n' "${credential}" "${scenario}" "${actual}" "${expected}" >&2
                exit 1
            fi
            if grep -REq 'fixture-(client|secret|token|body|header|private-host)|continued-after-auth-failure' "${case_dir}/console" "${case_dir}/artifacts"; then
                printf 'FAIL: unsafe output in %s/%s\n' "${credential}" "${scenario}" >&2
                exit 1
            fi
            if [[ "${scenario}" == *errexit || "${scenario}" == inline-* ]]; then
                test -s "${case_dir}/artifacts/controller-report.txt"
                test -s "${case_dir}/artifacts/controller-auth.jsonl"
            fi
            printf 'PASS: %s/%s\n' "${credential}" "${scenario}"
            count=$((count + 1))
        done
    done
    printf 'PASS: %s offline scenarios\n' "${count}"
    exit 0
fi

set +x
credential="$2" scenario="$3" case_dir="$4"
export CLUSTER_PROFILE_DIR="${case_dir}/profile" ARTIFACT_DIR="${case_dir}/artifacts"
mkdir -p "${CLUSTER_PROFILE_DIR}" "${ARTIFACT_DIR}"
case "${credential}" in
    client)
        printf fixture-client > "${CLUSTER_PROFILE_DIR}/sso-client-id"
        printf fixture-secret > "${CLUSTER_PROFILE_DIR}/sso-client-secret"
        printf fixture-token > "${CLUSTER_PROFILE_DIR}/ocm-token" ;;
    token) printf fixture-token > "${CLUSTER_PROFILE_DIR}/ocm-token" ;;
    partial)
        printf fixture-client > "${CLUSTER_PROFILE_DIR}/sso-client-id"
        printf fixture-token > "${CLUSTER_PROFILE_DIR}/ocm-token" ;;
    partial-missing) printf fixture-client > "${CLUSTER_PROFILE_DIR}/sso-client-id" ;;
esac
source "$(dirname "$0")/../ci-operator/step-registry/rosa/cluster-lease/controller/rosa-cluster-lease-controller-commands.sh"
test ! -e "${ARTIFACT_DIR}/controller-report.txt"
export OCM_LOGIN_ENV=staging
initialize_reports
: > "${case_dir}/calls"
: > "${case_dir}/sleeps"

sleep() { printf '%s\n' "$1" >> "${case_dir}/sleeps"; }
ocm() {
    [[ "$1" == login && "$2" == --url ]] || return 98
    if [[ "${credential}" == client ]]; then
        [[ "$4" == --client-id && "$5" == fixture-client && "$6" == --client-secret && "$7" == fixture-secret ]] || return 97
    else
        [[ "$4" == --token && "$5" == fixture-token ]] || return 97
    fi
    printf '%s\n' called >> "${case_dir}/calls"
    local calls
    calls=$(wc -l < "${case_dir}/calls")
    printf '%s\n' 'fixture-body fixture-client fixture-secret fixture-token fixture-header' >&2
    printf '%s\n' 'fixture-body fixture-token'
    case "${scenario}" in
        success|same-env|switch-success|inline-success) return 0 ;;
        switch-*|inline-switch-*) [[ "$3" == staging ]] && return 0 ;;
    esac
    case "${scenario}" in
        html-recovery|transport-*) [[ "${calls}" -ge 2 ]] && return 0 ;;
        switch-recovery) [[ "${calls}" -ge 3 ]] && return 0 ;;
    esac
    case "${scenario}" in
        permanent|switch-permanent|inline-permanent)
            echo 'invalid_client' >&2
            return 43 ;;
        mixed)
            echo 'invalid_client: connection reset by peer' >&2
            echo "expected response content type 'application/json' but received 'text/html'" >&2
            return 43 ;;
        unknown) echo 'an unrecognized authentication error' >&2; return 44 ;;
        near-miss) echo "expected response content type 'application/json' but received 'text/plain'" >&2; return 44 ;;
        transport-recovery) echo 'i/o timeout' >&2; return 42 ;;
        transport-tls) echo 'TLS handshake timeout' >&2; return 42 ;;
        transport-reset) echo 'connection reset by peer' >&2; return 42 ;;
        transport-eof) echo 'unexpected EOF' >&2; return 42 ;;
        transport-dns) echo 'temporary failure in name resolution' >&2; return 42 ;;
        transport-deadline) echo 'context deadline exceeded' >&2; return 42 ;;
    esac
    echo "expected response content type 'application/json' but received 'text/html'" >&2
    [[ "${scenario}" == final-exit ]] && return "$((40 + calls))"
    return 42
}

if [[ "${scenario}" == inline-* ]]; then
    oc() {
        [[ "$*" == *'get configmap'* ]] || return 96
        printf '%s\n' read >> "${case_dir}/reads"
        if [[ "$*" == *rosa-cluster-lease-config* ]]; then
            local environment=staging
            [[ "${scenario}" == inline-switch-exhaustion ]] && environment=production
            jq -n --arg desired "$(printf -- '- name: fixture-cluster\n  env: %s\n' "${environment}")" '{data:{"desired-clusters":$desired}}'
        else
            printf '%s\n' '{"items":[]}'
        fi
    }
    export -f ocm oc sleep
    export credential scenario case_dir
    touch "${case_dir}/lease-kubeconfig"
    script=$(< "${script_path}")
    fixture_script="${script/LEASE_HOST_KUBECONFIG=\"\/etc\/rosa-cluster-lease-manager\/kubeconfig\"/LEASE_HOST_KUBECONFIG=\"${case_dir}\/lease-kubeconfig\"}"
    test "${fixture_script}" != "${script}"
    rm "${REPORT}" "${AUTH_REPORT}"
    actual=0
    continuation=$'\necho continued-after-auth-failure'
    [[ "${scenario}" == inline-success ]] && continuation=''
    bash -x -c $'#!/bin/bash\nset -eu\n'"${fixture_script}${continuation}" || actual=$?
    if [[ "${scenario}" == inline-success ]]; then
        test "${actual}" -eq 0
        grep -q 'Summary' "${REPORT}"
    elif [[ "${scenario}" == inline-switch-exhaustion ]]; then
        test "$(wc -l < "${case_dir}/calls")" -eq 4
        test "$(wc -l < "${case_dir}/reads")" -eq 2
    else
        test ! -e "${case_dir}/reads"
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
expected_calls=1 expected_class=success
case "${credential}:${scenario}" in
    missing:*|partial-missing:*) test "${actual}" -eq 1; expected_calls=0; expected_class=missing_credentials ;;
    *:exhaustion|*:unsafe-env) test "${actual}" -eq 42; expected_calls=3; expected_class=retryable_html ;;
    *:permanent|*:mixed) test "${actual}" -eq 43; expected_class=permanent_auth ;;
    *:final-exit) test "${actual}" -eq 43; expected_calls=3; expected_class=retryable_html ;;
    *:unknown|*:near-miss) test "${actual}" -eq 44; expected_class=unclassified ;;
    *:html-recovery|*:transport-*) test "${actual}" -eq 0; expected_calls=2 ;;
    *) test "${actual}" -eq 0 ;;
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
        same-env) test "${actual}" -eq 0; test "${CURRENT_OCM_ENV}" = staging ;;
        *) test "${actual}" -eq 0; test "${CURRENT_OCM_ENV}" = production; expected_calls=2 ;;
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
    transport-*) jq -se 'any(.[]; .class == "retryable_transport" and .exit_code == 42)' "${AUTH_REPORT}" > /dev/null ;;
esac
case "${scenario}" in
    exhaustion|switch-exhaustion|final-exit) test "$(cat "${case_dir}/sleeps")" = $'10\n20' ;;
    html-recovery|transport-*|switch-recovery) test "$(cat "${case_dir}/sleeps")" = 10 ;;
    unsafe-env) test "$(cat "${case_dir}/sleeps")" = $'10\n20\n10\n20' ;;
    *) test ! -s "${case_dir}/sleeps" ;;
esac
if [[ "${actual}" -ne 0 && "${scenario}" != switch-* ]]; then
    test -z "${CURRENT_OCM_ENV}"
fi
