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
${TIMEOUT_COMMAND} ssh "${SSHOPTS[@]}" "root@${IP}" bash -s "${OPENSHIFT_TESTS_IMAGE}" "${GREP_FLAGS}" "${GREP_ARGS}" << "EOF"

    set -x

    function get_test_list() {
        podman run --network host --rm -i -e KUBECONFIG=/tmp/kubeconfig -v ${KUBECONFIG}:/tmp/kubeconfig $1 \
            openshift-tests run "openshift/conformance/parallel" --dry-run | \
            grep $2 $3
    }

    function run_tests() {
        podman run --network host --rm -i -v /tmp:/tmp -e KUBECONFIG=/tmp/kubeconfig -v ${kubeconfig}:/tmp/kubeconfig $1 \
            openshift-tests run -o /tmp/artifacts/e2e_${name}.log --junit-dir /tmp/artifacts/reports -f -
    }

    for kubeconfig in $(find ${KUBECONFIG} -type f); do
        export KUBECONFIG=${kubeconfig}
        name=$(basename ${kubeconfig})

        stderr=$( { get_test_list $1 $2 $3 | run_tests $1; } 2>&1)
        exit_code=\$?

        echo "\${stderr}"

        if [[ \${exit_code} -ne 0 ]]; then
            exit \${exit_code}
        fi
    done
EOF

exit_code=$?

set -e
echo "### Done! (${exit_code})"
exit $exit_code
