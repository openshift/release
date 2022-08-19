#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ assisted common verify command ************"

# TODO: Remove once OpenShift CI will be upgraded to 4.2 (see https://access.redhat.com/articles/4859371)
~/fix_uid.sh

if [ "${TEST_SUITE:-full}" == "none" ]; then
    echo "No need to run tests"
    exit 0
fi

collect_artifacts() {
    echo "### Fetching results"
    ssh -F ${SHARED_DIR}/ssh_config "root@ci_machine" tar -czf - /tmp/artifacts | tar -C "${ARTIFACT_DIR}" -xzf -
}

trap collect_artifacts EXIT TERM

# Tests execution
set +e

echo "### Copying test-list file"
scp -F ${SHARED_DIR}/ssh_config "${SHARED_DIR}/test-list" "root@ci_machine:/tmp/test-list"

echo "### Running tests"
timeout --kill-after 5m 120m ssh -F ${SHARED_DIR}/ssh_config "root@ci_machine" bash - << EOF
    # download openshift-tests cli tool from container quay.io/openshift/origin-tests
    CONTAINER_ID=\$(podman run -d quay.io/openshift/origin-tests)
    podman cp \${CONTAINER_ID}:/usr/bin/openshift-tests /usr/local/bin/
    podman rm -f \${CONTAINER_ID}

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
