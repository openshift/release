#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds test command ************"

collect_artifacts() {
    echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_END"

    echo "### Fetching results"
    ssh "${SSHOPTS[@]}" "root@${IP}" tar -czf - /tmp/artifacts | tar -C "${ARTIFACT_DIR}" -xzf -
}
trap collect_artifacts EXIT TERM

function copy_test_binaries() {
    # Copy test binaries on packet server
    echo "### Copying test binaries"
    scp "${SSHOPTS[@]}" /usr/bin/openshift-tests /usr/bin/kubectl "root@${IP}:/usr/local/bin"
}

function mirror_test_images() {
        echo "### Mirroring test images"

        DEVSCRIPTS_TEST_IMAGE_REPO=${DS_REGISTRY}/localimages/local-test-image
        # shellcheck disable=SC2087
        ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF
openshift-tests images --to-repository ${DEVSCRIPTS_TEST_IMAGE_REPO} > /tmp/mirror
oc image mirror -f /tmp/mirror --registry-config ${DS_WORKING_DIR}/pull_secret.json
EOF
        TEST_ARGS="--from-repository ${DEVSCRIPTS_TEST_IMAGE_REPO}"
}

function use_minimal_test_list() {
        echo "### Skipping test images mirroring, fall back to minimal tests list"

        TEST_ARGS="--file /tmp/tests"
        TEST_SKIPS=""
        echo "${TEST_MINIMAL_LIST}" > /tmp/tests
}

case "${CLUSTER_TYPE}" in
packet)
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/packet-conf.sh"
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/ds-vars.conf"
    copy_test_binaries

    # Currently all v6 deployments are disconnected, so we have to tell
    # openshift-tests to exclude those tests that require internet
    # access.
    if [[ "${DS_IP_STACK}" == "v6" ]];
    then
        export TEST_PROVIDER='\{\"type\":\"baremetal\",\"disconnected\":true\}'
    else
        export TEST_PROVIDER='\{\"type\":\"baremetal\"\}'
    fi

    echo "### Checking release version"
    # Mirroring test images is supported only for versions greater than or equal to 4.7
    if ! printf '%s\n%s' "4.8" "${DS_OPENSHIFT_VERSION}" | sort -C -V; then
        use_minimal_test_list
    elif [[ "${DS_IP_STACK}" == "v6" ]]; then
        # If we are on 4.8 or later, and IPv6 (disconnected) then let's
        # mirror images
        mirror_test_images
    fi
    ;;
*) echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"; exit 1;;
esac

function upgrade() {
    set -x
    ssh "${SSHOPTS[@]}" "root@${IP}" \
        openshift-tests run-upgrade all \
        --to-image "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}" \
        --provider "${TEST_PROVIDER:-}" \
        -o "/tmp/artifacts/e2e.log" \
        --junit-dir "/tmp/artifacts/junit"
    set +x
}

function suite() {
    if [[ -n "${TEST_SKIPS}" ]]; then
        TESTS="$(ssh "${SSHOPTS[@]}" "root@${IP}" openshift-tests run --dry-run --provider "${TEST_PROVIDER}" "${TEST_SUITE}")"
        echo "${TESTS}" | grep -v "${TEST_SKIPS}" >/tmp/tests
        echo "Skipping tests:"
        echo "${TESTS}" | grep "${TEST_SKIPS}"
        TEST_ARGS="${TEST_ARGS:-} --file /tmp/tests"
    fi

    scp "${SSHOPTS[@]}" /tmp/tests "root@${IP}:/tmp/tests"

    set -x
    ssh "${SSHOPTS[@]}" "root@${IP}" \
        openshift-tests run "${TEST_SUITE}" "${TEST_ARGS:-}" \
        --provider "${TEST_PROVIDER:-}" \
        -o "/tmp/artifacts/e2e.log" \
        --junit-dir "/tmp/artifacts/junit"
    set +x
}

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_START"

case "${TEST_TYPE}" in
upgrade-conformance)
    upgrade
    TEST_LIMIT_START_TIME="$(date +%s)" TEST_SUITE=openshift/conformance/parallel suite
    ;;
upgrade)
    upgrade
    ;;
suite-conformance)
    suite
    TEST_LIMIT_START_TIME="$(date +%s)" TEST_SUITE=openshift/conformance/parallel suite
    ;;
suite)
    suite
    ;;
*)
    echo >&2 "Unsupported test type '${TEST_TYPE}'"
    exit 1
    ;;
esac
