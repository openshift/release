#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_START"
trap 'echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_END"' EXIT

TEST_ARGS=""

if [[ -n "${TEST_SKIPS:-}" ]]; then
    TESTS="$(openshift-tests run all --dry-run)"
    echo "${TESTS}" | grep -v "${TEST_SKIPS}" >/tmp/tests
    echo "Skipping tests:"
    echo "${TESTS}" | grep "${TEST_SKIPS}" || true
    TEST_ARGS="--file /tmp/tests"
fi

openshift-tests run all ${TEST_ARGS} \
    -o "${ARTIFACT_DIR}/e2e.log" \
    --junit-dir "${ARTIFACT_DIR}/junit"
