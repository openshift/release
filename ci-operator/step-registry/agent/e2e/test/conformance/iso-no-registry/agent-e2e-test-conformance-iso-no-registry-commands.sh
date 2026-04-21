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

# Run the filtered tests
echo "${TESTS}" | openshift-tests run \
    --monitor "watch-namespaces" \
    --max-parallel-tests 1 \
    -f - \
    -o "${ARTIFACT_DIR}/e2e.log" \
    --junit-dir "${ARTIFACT_DIR}/junit"
