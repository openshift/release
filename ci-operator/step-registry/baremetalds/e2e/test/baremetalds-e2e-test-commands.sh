#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function mirror_test_images() {
        echo "### Mirroring test images"

        DEVSCRIPTS_TEST_IMAGE_REPO=${DS_REGISTRY}/localimages/local-test-image
        
        openshift-tests images --to-repository ${DEVSCRIPTS_TEST_IMAGE_REPO} > /tmp/mirror
        scp "${SSHOPTS[@]}" /tmp/mirror "root@${IP}:/tmp/mirror"

        # shellcheck disable=SC2087
        ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF
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

function set_test_provider() {
    # Currently all v6 deployments are disconnected, so we have to tell
    # openshift-tests to exclude those tests that require internet
    # access.
    if [[ "${DS_IP_STACK}" != "v6" ]];
    then
        export TEST_PROVIDER='{"type":"baremetal"}'
    else
        export TEST_PROVIDER='{"type":"baremetal","disconnected":true}'
    fi
}

function setup_proxy() {
    # For disconnected or otherwise unreachable environments, we want to
    # have steps use an HTTP(S) proxy to reach the API server. This proxy
    # configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
    # environment variables, as well as their lowercase equivalents (note
    # that libcurl doesn't recognize the uppercase variables).
    if test -f "${SHARED_DIR}/proxy-conf.sh"
    then
        # shellcheck source=/dev/null
        source "${SHARED_DIR}/proxy-conf.sh"
    fi
}

function is_openshift_version_gte() {
    printf '%s\n%s' "$1" "${DS_OPENSHIFT_VERSION}" | sort -C -V
}

case "${CLUSTER_TYPE}" in
packet)
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/packet-conf.sh"
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/ds-vars.conf"
        
    setup_proxy
    export KUBECONFIG=${SHARED_DIR}/kubeconfig

    echo "### Checking release version"
    if is_openshift_version_gte "4.8"; then
        # Set test provider for only versions greater than or equal to 4.8
        set_test_provider

        # Mirroring test images is supported only for versions greater than or equal to 4.8
        mirror_test_images

        # Skipping proxy related tests ([Skipped:Proxy]) is supported only for version  greater than or equal to 4.10
        # For lower versions they must be skipped manually
        if ! is_openshift_version_gte "4.10"; then
            TEST_SKIPS="${TEST_SKIPS}
${TEST_SKIPS_PROXY}"
        fi
    else
        export TEST_PROVIDER='{"type":"skeleton"}'
        use_minimal_test_list
    fi
    ;;
*) echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"; exit 1;;
esac

function upgrade() {
    set -x
    openshift-tests run-upgrade all \
        --to-image "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}" \
        --provider "${TEST_PROVIDER:-}" \
        -o "${ARTIFACT_DIR}/e2e.log" \
        --junit-dir "${ARTIFACT_DIR}/junit"
    set +x
}

function suite() {
    if [[ -n "${TEST_SKIPS}" ]]; then       
        TESTS="$(openshift-tests run --dry-run --provider "${TEST_PROVIDER}" "${TEST_SUITE}")" &&
        echo "${TESTS}" | grep -v "${TEST_SKIPS}" >/tmp/tests &&
        echo "Skipping tests:" &&
        echo "${TESTS}" | grep "${TEST_SKIPS}" || { exit_code=$?; echo 'Error: no tests were found matching the TEST_SKIPS regex:'; echo "$TEST_SKIPS"; return $exit_code; } &&
        TEST_ARGS="${TEST_ARGS:-} --file /tmp/tests"
    fi

    set -x
    openshift-tests run "${TEST_SUITE}" ${TEST_ARGS:-} \
        --provider "${TEST_PROVIDER:-}" \
        -o "${ARTIFACT_DIR}/e2e.log" \
        --junit-dir "${ARTIFACT_DIR}/junit"
    set +x
}

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_START"
trap 'echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_END"' EXIT

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
