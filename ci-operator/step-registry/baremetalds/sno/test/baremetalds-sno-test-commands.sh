#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ baremetalds single-node test command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

collect_artifacts() {
    echo "### Fetching results"
    ssh "${SSHOPTS[@]}" "root@${IP}" tar -czf - /tmp/artifacts | tar -C "${ARTIFACT_DIR}" -xzf -
}
trap collect_artifacts EXIT TERM

# Copy test binaries on packet server
echo "### Copying test binaries"
scp "${SSHOPTS[@]}" /usr/bin/openshift-tests /usr/bin/kubectl "root@${IP}:/usr/local/bin"

# Tests execution
set +e

export GREP_FLAGS=""
export GREP_ARGS="'Feature:ProjectAPI'"
export TIMEOUT_COMMAND=""

if [[ -s "${SHARED_DIR}/test-list" ]]; then
    echo "### Copying test-list file"
    scp \
        "${SSHOPTS[@]}" \
        "${SHARED_DIR}/test-list" \
        "root@${IP}:/tmp/test-list"

    GREP_FLAGS="-Ff"
    GREP_ARGS="/tmp/test-list"
    TIMEOUT_COMMAND="timeout --kill-after 10m 120m"
fi

echo "### Running tests"
${TIMEOUT_COMMAND} \
ssh \
    "${SSHOPTS[@]}" \
    "root@${IP}" \
    bash - << EOF
    stderr=\$( { openshift-tests run "openshift/conformance/parallel" --dry-run |\
        grep ${GREP_FLAGS} ${GREP_ARGS} |\
        openshift-tests run -o /tmp/artifacts/e2e.log --junit-dir /tmp/artifacts/reports -f - ;} 2>&1)
    exit_code=\$?

    echo "\${stderr}"

    # TODO: remove this part once we fully handle the problem described at
    # https://issues.redhat.com/browse/MGMT-15555.
    # After 'openshift-tests' finishes validating the tests, it checks
    # the extra monitoring tests, so the following line only excludes those
    # kind of failures (rather than excluding all runs where the monitoring
    # tests have failed).
    if [[ "\${stderr}" == *"failed due to a MonitorTest failure" ]]; then
        echo "Overriding exit code because of MonitorTest failure"
        exit 0
    fi

    if [[ \${exit_code} -ne 0 ]]; then
        exit \${exit_code}
    fi
EOF

exit_code=$?

set -e
echo "### Done! (${exit_code})"
exit $exit_code
