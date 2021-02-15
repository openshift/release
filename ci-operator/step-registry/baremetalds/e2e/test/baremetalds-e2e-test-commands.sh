#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ baremetalds test command ************"

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

# Run tests in disconnected mode
echo "### Mirroring test images"

# shellcheck disable=SC2046
read -d '' DEVSCRIPTS_REGISTRY DEVSCRIPTS_WORKING_DIR <<<$(ssh "${SSHOPTS[@]}" "root@${IP}" "source /root/dev-scripts/common.sh; echo \$LOCAL_REGISTRY_DNS_NAME:\$LOCAL_REGISTRY_PORT; echo \$WORKING_DIR")
DEVSCRIPTS_TEST_IMAGE_REPO=${DEVSCRIPTS_REGISTRY}/localimages/local-test-image

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF
set -xeuo pipefail
openshift-tests images --to-repository ${DEVSCRIPTS_TEST_IMAGE_REPO} > /tmp/mirror
oc image mirror -f /tmp/mirror --registry-config ${DEVSCRIPTS_WORKING_DIR}/pull_secret.json
EOF

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
            "openshift/conformance/serial" \
            --from-repository ${DEVSCRIPTS_TEST_IMAGE_REPO} \
            -o /tmp/artifacts/e2e.log --junit-dir /tmp/artifacts/junit
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
