#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ baremetalds test command ************"

# Initial check
if [ "${CLUSTER_TYPE}" != "packet" ] ; then
    echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 0
fi

# Fetch packet server IP
IP=$(cat "${SHARED_DIR}/server-ip")

SSHOPTS=(-o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -i "${CLUSTER_PROFILE_DIR}/.packet-kni-ssh-privatekey")

collect_artifacts() {
    echo "### Fetching results"
    ssh "${SSHOPTS[@]}" "root@${IP}" tar -czf - /tmp/artifacts | tar -C "${ARTIFACT_DIR}" -xzf -
}
trap collect_artifacts EXIT

# Copy test binaries on packet server
echo "### Copying test binaries"
scp "${SSHOPTS[@]}" /usr/bin/openshift-tests /usr/bin/kubectl "root@${IP}:/usr/local/bin"

# Tests execution
set +e

# Test upgrade for workflows that requested it
if [[ "$RUN_UPGRADE_TEST" == true ]]; then
    echo "### Running Upgrade tests"
    timeout \
    --kill-after 10m \
    120m \
        ssh \
            "${SSHOPTS[@]}" \
            "root@${IP}" \
            openshift-tests \
            run-upgrade \
            --to-image "$OPENSHIFT_UPGRADE_RELEASE_IMAGE" \
            -o /tmp/artifacts/e2e-upgrade.log \
            --junit-dir /tmp/artifacts/junit-upgrade \
            platform
else
    if [[ -s "${SHARED_DIR}/test-list" ]]; then
        echo "### Copying test-list file"
        scp \
            "${SSHOPTS[@]}" \
            "${SHARED_DIR}/test-list" \
            "root@${IP}:/tmp/test-list"
        echo "### Running tests"
        ssh \
            "${SSHOPTS[@]}" \
            "root@${IP}" \
            openshift-tests \
            run \
            "openshift/conformance/parallel" \
            --dry-run \
            \| grep -Ff /tmp/test-list \|openshift-tests run -o /tmp/artifacts/e2e.log --junit-dir /tmp/artifacts/junit -f -
    else
        echo "### Running tests"
        ssh \
            "${SSHOPTS[@]}" \
            "root@${IP}" \
            openshift-tests \
            run \
            "openshift/conformance/parallel" \
            --dry-run \
            \| grep 'Feature:ProjectAPI' \| openshift-tests run -o /tmp/artifacts/e2e.log --junit-dir /tmp/artifacts/junit -f -
    fi
fi

rv=$?

set -e
echo "### Done! (${rv})"
exit $rv
