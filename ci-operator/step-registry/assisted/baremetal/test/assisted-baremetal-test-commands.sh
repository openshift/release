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

# Copy test binaries on packet server
echo "### Copying test binaries"
scp "${SSHOPTS[@]}" /usr/bin/openshift-tests /usr/bin/kubectl "root@${IP}:/usr/local/bin"

# Tests execution
set +e

echo "### Copying test-list file"
scp "${SSHOPTS[@]}" "${SHARED_DIR}/test-list" "root@${IP}:/tmp/test-list"

echo "### Running tests"
timeout --kill-after 10m 120m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF
    for kubeconfig in \$(find \${KUBECONFIG} -type f); do
        export KUBECONFIG=\${kubeconfig}
        name=\$(basename \${kubeconfig})
        openshift-tests run "openshift/conformance/parallel" --dry-run | \
            grep -Ff /tmp/test-list | \
            openshift-tests run -o /tmp/artifacts/e2e_\${name}.log --junit-dir /tmp/artifacts/reports -f -
    done
EOF


rv=$?

set -e
echo "### Done! (${rv})"
exit $rv