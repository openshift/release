#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
controller=${1:-${repo_root}/ci-operator/step-registry/rosa/cluster-lease/controller/rosa-cluster-lease-controller-commands.sh}
phase_five=$(sed -n '/^log "Phase 5:/,/^# Phase 6:/{ /^# Phase 6:/d; p; }' "${controller}")
[[ -n "${phase_five}" ]]
test_dir=$(mktemp -d)
trap 'rm -rf "${test_dir}"' EXIT

run_case() (
    scenario=$1
    error_at=$2
    created_at=$3
    expected=$4
    DRY_RUN=${5:-false}
    export LEASE_NAMESPACE=test-leases
    export NOW_EPOCH
    NOW_EPOCH=$(date -d '2026-01-02T12:00:00Z' +%s)
    export ERROR_THRESHOLD=3600
    REPORT=${test_dir}/${scenario}.report
    deleted=${test_dir}/${scenario}.deleted
    : > "${REPORT}"
    inventory=$(jq -n --argjson annotations "${error_at}" --arg created "${created_at}" '{items: [{
        metadata: {name: "test-lease", creationTimestamp: $created, annotations: $annotations},
        data: {"cluster-id": "test-cluster", "ocm-env": "staging"}
    }]}')

    log() { printf '%s\n' "$*"; }
    dry_run_guard() { [[ "${DRY_RUN}" == true ]]; }
    lease_oc() {
        case "$*" in
            'get configmap -n test-leases -l rosa-cluster-lease/managed=true,rosa-cluster-lease/status=error -o json')
                printf '%s\n' "${inventory}"
                ;;
            'delete configmap test-lease -n test-leases')
                touch "${deleted}"
                ;;
            *) return 1 ;;
        esac
    }
    ocm_ensure_env() { [[ "$1" == staging ]]; }
    ocm_check_cluster() {
        [[ "$1" == test-cluster && "$2" == staging ]]
        export OCM_CHECK_RESULT=not-found
    }
    delete_cluster() { return 1; }

    eval "${phase_five}"

    if [[ "${expected}" == replace ]]; then
        [[ -f "${deleted}" ]]
        grep -q '^REPLACE: test-lease ' "${REPORT}"
    elif [[ "${expected}" == dry-run ]]; then
        [[ ! -f "${deleted}" ]]
        grep -q '^REPLACE: test-lease ' "${REPORT}"
    else
        [[ ! -f "${deleted}" && ! -s "${REPORT}" ]]
    fi
    printf 'PASS: %s\n' "${scenario}"
)

run_case missing-error-at '{}' '2026-01-02T10:00:00Z' replace
run_case empty-error-at '{"rosa-cluster-lease/error-at":""}' '2026-01-02T10:00:00Z' replace
run_case null-error-at '{"rosa-cluster-lease/error-at":null}' '2026-01-02T10:00:00Z' replace
run_case missing-annotations null '2026-01-02T10:00:00Z' replace
run_case recent-creation '{}' '2026-01-02T11:30:00Z' wait
run_case threshold-boundary '{}' '2026-01-02T11:00:00Z' replace
run_case explicit-recent-error '{"rosa-cluster-lease/error-at":"2026-01-02T11:30:00Z"}' '2026-01-02T10:00:00Z' wait
run_case explicit-old-error '{"rosa-cluster-lease/error-at":"2026-01-02T10:00:00Z"}' '2026-01-02T11:30:00Z' replace
run_case missing-timestamps '{}' '' wait
run_case dry-run '{}' '2026-01-02T10:00:00Z' dry-run true
