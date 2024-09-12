#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ baremetalds assisted test command ************"

if [ "${TEST_TYPE:-list}" == "none" ]; then
    echo "No need to run tests"
    exit 0
fi

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

echo "### Running tests"
timeout --kill-after 10m 120m ssh "${SSHOPTS[@]}" "root@${IP}" "bash -s \"${OPENSHIFT_TESTS_IMAGE}\" \"${TEST_TYPE:-"list"}\" \"${TEST_SUITE:-"openshift/conformance/parallel"}\" \"${TEST_LIST:-""}\" \"${TEST_PROVIDER:-"baremetal"}\" \"${TEST_SKIPS}\"" << "EOF"
    set -x

    openshift_tests_image="$1"
    test_type="$2"
    test_suite="$3"
    test_list="$4"
    test_provider="$5"
    test_skips="$6"
    test_list_file="/tmp/test-list"
    test_skips_file="/tmp/test-skips"

    function get_baremetal_test_list() {
        podman run --network host --rm -i \
            -e KUBECONFIG=/tmp/kubeconfig -v "${KUBECONFIG}:/tmp/kubeconfig" "${openshift_tests_image}" \
            openshift-tests run "${test_type}" \
            --dry-run \
            --provider "{\"type\": \"${test_suite}\"}"
    }

    function run_tests() {
        podman run --network host --rm -i -v /tmp:/tmp -e KUBECONFIG=/tmp/kubeconfig -v "${KUBECONFIG}:/tmp/kubeconfig" "${openshift_tests_image}" \
            openshift-tests run -o "/tmp/artifacts/e2e_${name}.log" --junit-dir /tmp/artifacts/reports --file "${test_list_file}"
    }
    
    # prepending each printed line with a timestamp
    exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0 }') 2>&1

    for kubeconfig in $(find "${KUBECONFIG}" -type f); do
        export KUBECONFIG="${kubeconfig}"
        name=$(basename "${kubeconfig}")

        case ${test_type} in
            suite)
                test_list=$(get_baremetal_test_list)
                ;;
            list)
                ;;
            *)
                echo >&2 "Unsupported TEST_TYPE: ${test_type}"
                exit 1
                ;;
        esac

        echo "${test_skips}" > "${test_skips_file}"
        echo "${test_list}" | grep -v -F -f "${test_skips_file}" > "${test_list_file}"

        stderr=$(run_tests 2>&1)
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

sleep 3600
exit_code=$?

set -e
echo "### Done! (${exit_code})"
exit $exit_code
