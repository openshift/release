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
    set -o pipefail

    readonly STABILITY_TIMEOUT_SECONDS=600
    readonly STABLE_PERIOD_SECONDS=120
    readonly POLL_INTERVAL_SECONDS=5
    CONTROL_PLANE_OPERATORS=(kube-apiserver kube-controller-manager kube-scheduler etcd)

    function wait_for_stable_control_plane() {
        local deadline=$((SECONDS + STABILITY_TIMEOUT_SECONDS))
        local stable_since=""

        echo "Waiting for the API and control-plane operators to stay stable for ${STABLE_PERIOD_SECONDS}s"
        while (( SECONDS < deadline )); do
            if oc --request-timeout=5s get --raw /readyz >/dev/null 2>&1 &&
                oc --request-timeout=5s get clusteroperators "${CONTROL_PLANE_OPERATORS[@]}" -o json |
                jq -e '
                    (.items | length == 4) and
                    all(.items[];
                        any(.status.conditions[]?; .type == "Available" and .status == "True") and
                        any(.status.conditions[]?; .type == "Progressing" and .status == "False") and
                        any(.status.conditions[]?; .type == "Degraded" and .status == "False")
                    )
                ' >/dev/null; then
                if [[ -z "${stable_since}" ]]; then
                    stable_since=${SECONDS}
                fi
                if (( SECONDS < deadline && SECONDS - stable_since >= STABLE_PERIOD_SECONDS )); then
                    return 0
                fi
            else
                stable_since=""
            fi
            sleep "${POLL_INTERVAL_SECONDS}"
        done

        echo "ERROR: control plane did not stabilize within ${STABILITY_TIMEOUT_SECONDS}s" >&2
        oc --request-timeout=5s get clusteroperators "${CONTROL_PLANE_OPERATORS[@]}" || true
        return 1
    }

    function get_test_list() {
        podman run --network host --rm -i -e KUBECONFIG=/tmp/kubeconfig -v ${KUBECONFIG}:/tmp/kubeconfig $1 \
            openshift-tests run "openshift/conformance/parallel" --dry-run | \
            grep $2 $3
    }

    function run_tests() {
        podman run --network host --rm -i -v /tmp:/tmp -e KUBECONFIG=/tmp/kubeconfig -v ${kubeconfig}:/tmp/kubeconfig $1 \
            openshift-tests run -o /tmp/artifacts/e2e_${name}.log --junit-dir /tmp/artifacts/reports -f -
    }

    test_list=$(mktemp) || exit 1
    trap 'rm -f "${test_list}"' EXIT

    for kubeconfig in $(find ${KUBECONFIG} -type f); do
        export KUBECONFIG=${kubeconfig}
        name=$(basename ${kubeconfig})

        wait_for_stable_control_plane || exit $?

        # Discovery also needs the API. Do not start tests with partial or empty input.
        get_test_list "$1" "$2" "$3" > "${test_list}"
        exit_code=$?
        if [[ ${exit_code} -ne 0 ]]; then
            echo "ERROR: test discovery failed (${exit_code}); tests were not started" >&2
            exit "${exit_code}"
        fi
        if [[ ! -s "${test_list}" ]]; then
            echo "ERROR: test discovery selected no tests" >&2
            exit 1
        fi

        run_tests "$1" < "${test_list}"
        exit_code=$?
        if [[ ${exit_code} -ne 0 ]]; then
            exit "${exit_code}"
        fi
    done
EOF

exit_code=$?

set -e
echo "### Done! (${exit_code})"
exit $exit_code
