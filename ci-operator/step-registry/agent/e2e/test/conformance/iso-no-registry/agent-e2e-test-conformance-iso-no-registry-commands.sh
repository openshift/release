#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

date +%s > "${SHARED_DIR}/TEST_TIME_TEST_START"
trap 'date +%s > "${SHARED_DIR}/TEST_TIME_TEST_END"' EXIT

# Get all tests filtered for NoRegistryClusterInstall
ALL_TESTS="$(openshift-tests run all --provider '{"type":"baremetal"}' --dry-run)"
TESTS="$(printf '%s\n' "${ALL_TESTS}" | grep -E 'NoRegistryClusterInstall' || true)"
if [[ -z "${TESTS}" ]]; then
    echo "No tests matched NoRegistryClusterInstall"
    exit 1
fi

# Apply TEST_SKIPS filter if set
if [[ -n "${TEST_SKIPS:-}" ]]; then
    echo "Skipping tests matching: ${TEST_SKIPS}"
    echo "${TESTS}" | grep -E -- "${TEST_SKIPS}" || true
    set +e
    FILTERED_TESTS="$(printf '%s\n' "${TESTS}" | grep -Ev -- "${TEST_SKIPS}")"
    grep_status=$?
    set -e
    if [[ ${grep_status} -eq 2 ]]; then
        echo "Invalid TEST_SKIPS regex: ${TEST_SKIPS}" >&2
	exit 1
    fi
    if [[ -z "${FILTERED_TESTS}" ]]; then
        echo "All candidate tests were filtered by TEST_SKIPS=${TEST_SKIPS}"
        exit 1
    fi
    TESTS="${FILTERED_TESTS}"
fi

select_tests() {
    local tests
    tests="$(printf '%s\n' "${TESTS}" | grep -E "$1" || true)"
    printf '%s\n' "${tests}"
}

PARALLEL="$(select_tests parallel)"
SERIAL="$(select_tests serial)"
DISRUPTIVE="$(select_tests Disruptive)"

run_tests() {
    local suite="$1" tests="$2"
    local -a parallelism=(--max-parallel-tests 5)
    if [[ -z "${tests}" ]]; then
        echo "No NoRegistryClusterInstall tests selected for ${suite}"
        return
    fi
    if [[ "${suite}" != parallel ]]; then
        parallelism=(--max-parallel-tests 1)
    fi

    echo "${tests}" | openshift-tests run \
        --monitor "watch-namespaces" \
        "${parallelism[@]}" \
        -f - \
        -o "${ARTIFACT_DIR}/e2e-${suite}.log" \
        --junit-dir "${ARTIFACT_DIR}/junit/${suite}"

    junit_files=("${ARTIFACT_DIR}/junit/${suite}"/junit_e2e_*.xml)
    if [[ ! -f "${junit_files[0]}" ]]; then
        echo "ERROR: no junit_e2e_*.xml file found for ${suite}"
        exit 1
    fi
    while IFS= read -r skipped; do
        if [[ "${skipped}" -gt 0 ]]; then
            echo "ERROR: ${skipped} IRI test(s) were skipped in ${suite}"
            exit 1
        fi
    done < <(sed -n 's/.*skipped="\([0-9]*\)".*/\1/p' "${junit_files[@]}")
}

run_tests parallel "${PARALLEL}"
run_tests serial "${SERIAL}"
run_tests disruptive "${DISRUPTIVE}"
