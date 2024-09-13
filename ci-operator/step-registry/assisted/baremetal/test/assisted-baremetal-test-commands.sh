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

echo "### Prepare test environment"

test_list_file="test-list"
test_skips_file="test-skips"
test_env_file="test-env"

echo "${TEST_LIST:-""}" > "${ARTIFACT_DIR}/${test_list_file}"
echo "${TEST_SKIPS:-""}" > "${ARTIFACT_DIR}/${test_skips_file}"
cat << EOF > "${ARTIFACT_DIR}/${test_env_file}"
openshift_tests_image="${OPENSHIFT_TESTS_IMAGE}"
test_type="${TEST_TYPE:-"list"}"
test_suite="${TEST_SUITE:-"openshift/conformance/parallel"}"
test_provider="${TEST_PROVIDER:-"baremetal"}"
test_list_file="/tmp/${test_list_file}"
test_skips="/tmp/${test_skips_file}"
EOF

timeout --kill-after 10m 120m scp "${SSHOPTS[@]}"   \
    "${ARTIFACT_DIR}/${test_list_file}"             \
    "${ARTIFACT_DIR}/${test_skips_file}"            \
    "${ARTIFACT_DIR}/${test_env_file}"              \
    "root@${IP}:/tmp"

echo "### Running tests"
timeout --kill-after 10m 120m ssh "${SSHOPTS[@]}" "root@${IP}" "bash -s" << "EOF"
    set -x

    source /tmp/test-env

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
                get_baremetal_test_list > "${test_list_file}"
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
