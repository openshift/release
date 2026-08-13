#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export HOME=/tmp/home
mkdir -p "${HOME}"
mkdir -p "${ARTIFACT_DIR}/junit"

# Decompress and prepare the CBO test extension binary
echo "Preparing cluster-baremetal-operator test extension binary..."
BINARY=/tmp/cluster-baremetal-operator-tests-ext
gunzip -c /usr/bin/cluster-baremetal-operator-tests-ext.gz > "${BINARY}"
chmod +x "${BINARY}"

# Verify binary
${BINARY} info

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_START"
echo "Running CBO test suite: ${TEST_SUITE}"

ret_value=0
${BINARY} run-suite -c 1 --junit-path "${ARTIFACT_DIR}/junit.xml" "${TEST_SUITE}" || ret_value=$?

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_END"

if [ "${ret_value}" -eq 0 ]; then
    echo "CBO extension tests passed"
    exit 0
else
    echo "CBO extension tests failed with exit code ${ret_value}"
    exit "${ret_value}"
fi
