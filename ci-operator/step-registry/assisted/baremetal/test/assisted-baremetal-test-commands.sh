#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x


if [ "${TEST_SUITE:-full}" == "none" ]; then
    echo "No need to run tests"
    exit 0
fi

echo "************ baremetalds assisted test command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

collect_artifacts() {
    echo "### Fetching results"
    ssh "${SSHOPTS[@]}" "root@${IP}" tar -czf - /tmp/artifacts | tar -C "${ARTIFACT_DIR}" -xzf -
}
trap collect_artifacts EXIT TERM

# Tests execution
set +e

echo "### Copying test-list file"
scp "${SSHOPTS[@]}" "${SHARED_DIR}/test-list" "root@${IP}:/tmp/test-list"

echo "### Running tests"
timeout --kill-after 10m 120m ssh "${SSHOPTS[@]}" "root@${IP}" bash -s "${OPENSHIFT_TESTS_IMAGE}" << "EOF"
    set -x

    function get_test_list() {
        podman run --network host --rm -i -e KUBECONFIG=/tmp/kubeconfig -v ${kubeconfig}:/tmp/kubeconfig $1 \
            openshift-tests run "openshift/conformance/parallel" --dry-run | \
            grep -Ff /tmp/test-list
    }

    function run_tests() {
        podman run --network host --rm -i -v /tmp:/tmp -e KUBECONFIG=/tmp/kubeconfig -v ${kubeconfig}:/tmp/kubeconfig $1 \
            openshift-tests run -o /tmp/artifacts/e2e_${name}.log --junit-dir /tmp/artifacts/reports -f -
    }
    
    # prepending each printed line with a timestamp
    exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0 }') 2>&1

    for kubeconfig in $(find ${KUBECONFIG} -type f); do
        export KUBECONFIG=${kubeconfig}
        name=$(basename ${kubeconfig})

        stderr=$( { get_test_list $1 | run_tests $1; } 2>&1 )
        exit_code=$?
        
        # TODO: remove this part once we fully handle the problem described at
        # https://issues.redhat.com/browse/MGMT-15555.
        # After 'openshift-tests' finishes validating the tests, it checks
        # the extra monitoring tests, so the following line only excludes those
        # kind of failures (rather than excluding all runs where the monitoring
        # tests have failed).
        if [[ "${stderr}" == *"failed due to a MonitorTest failure" ]]; then
            continue
        fi

        if [[ ${exit_code} -ne 0 ]]; then
            exit ${exit_code}
        fi
    done
EOF


exit_code=$?

set -e
echo "### Done! (${exit_code})"
exit $exit_code
